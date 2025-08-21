import * as functions from "firebase-functions";
import * as admin from "firebase-admin";
import Stripe from "stripe";
import * as dotenv from "dotenv";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import * as crypto from 'crypto';
dotenv.config();

admin.initializeApp();
const db = admin.firestore();

/** 必須環境変数チェック（未設定ならわかりやすく失敗させる） */
function requireEnv(name: string): string {
  const v = process.env[name];
  if (!v) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      `Server misconfigured: missing ${name}`
    );
  }
  return v;
}


/** Stripe クライアントは遅延初期化（env 未設定でのモジュールロード失敗を防ぐ） */
let _stripe: Stripe | null = null;
function stripeClient(): Stripe {
  if (_stripe) return _stripe;
  _stripe = new Stripe(requireEnv("STRIPE_SECRET_KEY"), {
    apiVersion: "2023-10-16",
  });
  return _stripe!;
}



const APP_ORIGIN = functions.config().app?.origin || 'https://yourapp.example.com';

function sha256(s: string) {
  return crypto.createHash('sha256').update(s).digest('hex');
}

async function assertTenantAdmin(tenantId: string, uid: string) {
  // members/{uid}.role == 'admin' or tenant.memberUids includes uid
  const mem = await db.doc(`tenants/${tenantId}/members/${uid}`).get();
  if (mem.exists && (mem.data()?.role === 'admin')) return;
  const t = await db.doc(`tenants/${tenantId}`).get();
  const arr: string[] = (t.data()?.memberUids || []) as string[];
  if (arr.includes(uid)) return;
  throw new functions.https.HttpsError('permission-denied', 'Not tenant admin');
}

// /** 店舗が金額入力 → Checkout セッション発行（店舗用） */
// export const createCheckoutSession =
//   functions.region("us-central1")
//   .runWith({ secrets: ["STRIPE_SECRET_KEY", "FRONTEND_BASE_URL"], memory: "256MB" })
//   .https.onCall(async (data, ctx) => {
//     const { tenantId } = requireAuthAndTenant(ctx);
//     const { amount, currency = "JPY", memo = "" } = data as {
//       amount: number; currency?: string; memo?: string;
//     };

//     if (!Number.isInteger(amount) || amount <= 0) {
//       throw new functions.https.HttpsError("invalid-argument", "amount must be positive integer");
//     }

//     // テナントの稼働状態を確認
//     const tDoc = await db.collection("tenants").doc(tenantId).get();
//     if (!tDoc.exists || tDoc.data()!.status !== "active") {
//       throw new functions.https.HttpsError("failed-precondition", "Tenant suspended or not found");
//     }

//     const FRONTEND_BASE_URL = requireEnv("FRONTEND_BASE_URL");
//     const stripe = stripeClient();

//     try {
//       // Stripe Checkout Session 作成（Hosted）
//       const session = await stripe.checkout.sessions.create({
//         mode: "payment",
//         payment_method_types: ["card", "link"],
//         line_items: [
//           {
//             price_data: {
//               currency,
//               product_data: { name: `Order - ${tDoc.data()!.name}` },
//               unit_amount: amount,
//             },
//             quantity: 1,
//           },
//         ],
//         // Netlifyでも安全なハッシュ方式
//         success_url: `${FRONTEND_BASE_URL}/#/payer?sid={CHECKOUT_SESSION_ID}`,
//         cancel_url: `${FRONTEND_BASE_URL}/#/p?t=${tenantId}&canceled=true`,
//         metadata: { tenantId, memo },
//       });

//       // Firestore にセッション保存
//       await db.collection("paymentSessions").doc(session.id).set({
//         tenantId,
//         amount,
//         currency,
//         status: "pending",
//         stripeCheckoutUrl: session.url,
//         stripeSessionId: session.id,
//         createdAt: admin.firestore.FieldValue.serverTimestamp(),
//         expiresAt: admin.firestore.Timestamp.fromMillis(Date.now() + 30 * 60 * 1000), // 30分
//         memo,
//       });

//       return { checkoutUrl: session.url, sessionId: session.id };
//     } catch (err: any) {
//       // Stripe 由来の失敗をクライアントに分かりやすく返す
//       throw new functions.https.HttpsError(
//         "failed-precondition",
//         err?.message || "Stripe error",
//         { source: "stripe", code: err?.type || "stripe_error" }
//       );
//     }
//   });

export const stripeWebhook =
  functions.region("us-central1")
    .runWith({
      secrets: [
        "STRIPE_SECRET_KEY",
        "STRIPE_WEBHOOK_SECRET",
        "STRIPE_CONNECT_WEBHOOK_SECRET",
        "FRONTEND_BASE_URL",
      ],
      memory: "256MB",
    })
    .https.onRequest(async (req, res): Promise<void> => {
      const sig = req.headers["stripe-signature"] as string | undefined;
      if (!sig) {
        res.status(400).send("No signature");
        return;
      }

      const stripe = stripeClient();

      // 複数シークレットで検証（通常/Connect の両方に対応）
      const secrets = [
        process.env.STRIPE_WEBHOOK_SECRET,
        process.env.STRIPE_CONNECT_WEBHOOK_SECRET,
      ].filter(Boolean) as string[];

      let event: Stripe.Event | null = null;
      for (const secret of secrets) {
        try {
          event = stripe.webhooks.constructEvent(
            (req as any).rawBody, // Firebase Functions は rawBody を提供
            sig,
            secret
          );
          break; // 検証成功で抜ける
        } catch {
          // 次のシークレットで再トライ
        }
      }

      if (!event) {
        console.error("Webhook signature verification failed for all secrets.");
        res.status(400).send("Webhook Error: invalid signature");
        return;
      }

      const type = event.type;
      const docRef = db.collection("webhookEvents").doc(event.id);
      await docRef.set({
        type,
        receivedAt: admin.firestore.FieldValue.serverTimestamp(),
        handled: false,
      });

      try {
        if (type === "checkout.session.completed") {
  const session = event.data.object as Stripe.Checkout.Session;
  const sid = session.id;
  const tenantId = session.metadata?.tenantId as string | undefined;
  const employeeId = session.metadata?.employeeId as string | undefined;
  let employeeName = session.metadata?.employeeName as string | undefined;
  const payIntentId = session.payment_intent as string | undefined;

  if (!tenantId) {
    console.error("checkout.session.completed: missing tenantId in metadata");
  } else {
    const tRef = db.collection("tenants").doc(tenantId);

    // ---- 共通: サブコレ tipSessions を paid に ----
    await tRef.collection("tipSessions").doc(sid).set(
      {
        status: "paid",
        paidAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );

    // tips の docId: metadata.tipDocId -> payment_intent -> session.id
    const tipDocId =
      (session.metadata?.tipDocId as string | undefined) ||
      payIntentId ||
      sid;

    // 店舗名のフォールバック: metadata.storeName -> tenant.name -> "Store"
    let storeName = session.metadata?.storeName as string | undefined;
    if (!storeName) {
      const tSnap = await tRef.get();
      storeName = (tSnap.exists && (tSnap.data()?.name as string)) || "Store";
    }

    // 従業員チップなら employeeName が無い場合に従業員ドキュメントから補完
    if (employeeId && !employeeName) {
      const eSnap = await tRef.collection("employees").doc(employeeId).get();
      employeeName =
        (eSnap.exists && (eSnap.data()?.name as string)) || "Staff";
    }

    // 受取先：従業員 or 店舗
    const recipient = employeeId
      ? { type: "employee", employeeId, employeeName: employeeName || "Staff" }
      : { type: "store", storeName: storeName! };

    // 既存 createdAt を保持したいので一度読み出し
    const tipRef = tRef.collection("tips").doc(tipDocId);
    const tipSnap = await tipRef.get();
    const existingCreatedAt = tipSnap.exists ? tipSnap.data()?.createdAt : null;

    await tipRef.set(
      {
        tenantId,
        sessionId: sid,
        amount: session.amount_total ?? 0,
        currency: (session.currency ?? "jpy").toUpperCase(),
        status: "succeeded",
        stripePaymentIntentId: payIntentId ?? "",
        recipient,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        ...(existingCreatedAt
          ? { createdAt: existingCreatedAt }
          : { createdAt: admin.firestore.FieldValue.serverTimestamp() }),
      },
      { merge: true }
    );
  }
}


        if (type === 'checkout.session.expired') {
  const session = event.data.object as Stripe.Checkout.Session;
  await db.collection('tipSessions').doc(session.id).set(
    { status: 'expired', updatedAt: admin.firestore.FieldValue.serverTimestamp() },
    { merge: true }
  );
}

if (type === 'checkout.session.async_payment_failed') {
  const session = event.data.object as Stripe.Checkout.Session;
  await db.collection('tipSessions').doc(session.id).set(
    { status: 'failed', updatedAt: admin.firestore.FieldValue.serverTimestamp() },
    { merge: true }
  );
}


        // Connect アカウント状態の同期
        if (type === "account.updated") {
          const acct = event.data.object as Stripe.Account;
          const qs = await db
            .collection("tenants")
            .where("stripeAccountId", "==", acct.id)
            .limit(1)
            .get();

          if (!qs.empty) {
            const tRef = qs.docs[0].ref;
            await tRef.set(
              {
                connect: {
                  charges_enabled: !!acct.charges_enabled,
                  payouts_enabled: !!acct.payouts_enabled,
                  details_submitted: !!acct.details_submitted,
                  updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                },
              },
              { merge: true }
            );
          }
        }

        await docRef.set({ handled: true }, { merge: true });
        res.sendStatus(200);
        return;
      } catch (e) {
        console.error(e);
        res.sendStatus(500);
        return;
      }
    });


    export const createConnectAccountForTenant = onCall(
      {
        region: "us-central1",
        memory: "256MiB",
        cors: ["https://venerable-mermaid-fcf8c8.netlify.app", "http://localhost:5173"],
        secrets: ["STRIPE_SECRET_KEY"],
      },
      async (req) => {
        if (!req.auth) throw new HttpsError("unauthenticated", "auth required");
        const tenantId = req.data?.tenantId as string | undefined;
        if (!tenantId) throw new HttpsError("invalid-argument", "tenantId required");
    
        const tRef = db.collection("tenants").doc(tenantId);
        const tSnap = await tRef.get();
        if (!tSnap.exists) throw new HttpsError("not-found", "tenant not found");
        const existing = tSnap.data()?.stripeAccountId as string | undefined;
        if (existing) return { stripeAccountId: existing, already: true };
    
        const stripe = stripeClient();
        const acct = await stripe.accounts.create({
          type: "express",
          capabilities: { card_payments: { requested: true }, transfers: { requested: true } },
        });
    
        await tRef.set({
          stripeAccountId: acct.id,
          connect: {
            charges_enabled: !!acct.charges_enabled,
            payouts_enabled: !!acct.payouts_enabled,
            details_submitted: !!acct.details_submitted,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
        }, { merge: true });
    
        return { stripeAccountId: acct.id };
      }
    );
    
    export const createAccountOnboardingLink = onCall(
      {
        region: "us-central1",
        memory: "256MiB",
        cors: ["https://venerable-mermaid-fcf8c8.netlify.app", "http://localhost:5173"],
        secrets: ["STRIPE_SECRET_KEY", "FRONTEND_BASE_URL"],
      },
      async (req) => {
        if (!req.auth) throw new HttpsError("unauthenticated", "auth required");
        const tenantId = req.data?.tenantId as string | undefined;
        if (!tenantId) throw new HttpsError("invalid-argument", "tenantId required");
    
        const t = await db.collection("tenants").doc(tenantId).get();
        const acctId = t.data()?.stripeAccountId as string | undefined;
        if (!acctId) throw new HttpsError("failed-precondition", "no stripeAccountId");
    
        const stripe = stripeClient();
        const BASE = process.env.FRONTEND_BASE_URL!;
        const link = await stripe.accountLinks.create({
          account: acctId,
          type: "account_onboarding",
          refresh_url: `${BASE}/#/connect-refresh?t=${tenantId}`,
          return_url: `${BASE}/#/connect-return?t=${tenantId}`,
        });
        return { url: link.url };
      }
    );

    /** 1) 招待を作成してメール送信 */
export const inviteTenantAdmin = functions.https.onCall(async (data, context) => {
  const uid = context.auth?.uid;
  if (!uid) throw new functions.https.HttpsError('unauthenticated', 'Sign in');

  const tenantId: string = data?.tenantId;
  const emailRaw: string = (data?.email || '').toString();
  const emailLower = emailRaw.trim().toLowerCase();
  if (!tenantId || !emailLower.includes('@')) {
    throw new functions.https.HttpsError('invalid-argument', 'bad tenantId/email');
  }
  await assertTenantAdmin(tenantId, uid);

  // token作成（メールに入れるのは生token、DBにはhashだけ保存）
  const token = crypto.randomBytes(32).toString('hex');
  const tokenHash = sha256(token);
  const expiresAt = admin.firestore.Timestamp.fromDate(
    new Date(Date.now() + 1000 * 60 * 60 * 24 * 7) // 7日
  );

  const inviteRef = db.collection(`tenants/${tenantId}/invites`).doc();
  await inviteRef.set({
    emailLower,
    tokenHash,
    status: 'pending',
    invitedBy: {
      uid,
      email: context.auth?.token?.email || null,
    },
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    expiresAt,
  });

  const acceptUrl = `${APP_ORIGIN}/#/admin-invite?tenantId=${tenantId}&token=${token}`;

  // 送信方法A：Firebase Extension「Firestore Send Email」使用（/mailに積む）
  await db.collection('mail').add({
    to: emailLower,
    message: {
      subject: '管理者招待のお知らせ',
      html: `
        <p>管理者として招待されました。</p>
        <p><a href="${acceptUrl}">こちらのリンク</a>を開いて承認してください（7日以内）。</p>
        <p>リンク: ${acceptUrl}</p>
      `,
    },
  });

  // 送信方法B：SendGrid/SES等を直接呼ぶ場合はここでAPIコール

  return { ok: true };
});

/** 2) 受け入れ（ログイン済ユーザーが token を提出） */
export const acceptTenantAdmin = functions.https.onCall(async (data, context) => {
  const uid = context.auth?.uid;
  const userEmail = (context.auth?.token?.email || '').toLowerCase();
  if (!uid || !userEmail) {
    throw new functions.https.HttpsError('unauthenticated', 'Sign in with email');
  }

  const tenantId: string = data?.tenantId;
  const token: string = data?.token;
  if (!tenantId || !token) {
    throw new functions.https.HttpsError('invalid-argument', 'tenantId/token required');
  }
  const tokenHash = sha256(token);

  // 招待の検証（メール一致・未使用・未失効）
  const invitesSnap = await db
    .collection(`tenants/${tenantId}/invites`)
    .where('tokenHash', '==', tokenHash)
    .limit(1)
    .get();
  if (invitesSnap.empty) {
    throw new functions.https.HttpsError('not-found', 'Invite not found');
  }
  const inviteRef = invitesSnap.docs[0].ref;
  const inv = invitesSnap.docs[0].data();

  if (inv.status !== 'pending') {
    throw new functions.https.HttpsError('failed-precondition', 'Invite already used/revoked');
  }
  const now = admin.firestore.Timestamp.now();
  if (inv.expiresAt && now.toMillis() > inv.expiresAt.toMillis()) {
    throw new functions.https.HttpsError('deadline-exceeded', 'Invite expired');
  }
  if (inv.emailLower !== userEmail) {
    throw new functions.https.HttpsError('permission-denied', 'Email does not match invite');
  }

  // すでにadminならスキップ
  const memRef = db.doc(`tenants/${tenantId}/members/${uid}`);
  const mem = await memRef.get();
  if (!mem.exists) {
    // 追加
    await memRef.set({
      role: 'admin',
      email: userEmail,
      displayName: context.auth?.token?.name || null,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    await db.doc(`tenants/${tenantId}`).update({
      memberUids: admin.firestore.FieldValue.arrayUnion(uid),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  }

  // 招待を消費
  await inviteRef.update({
    status: 'accepted',
    acceptedBy: uid,
    acceptedAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  return { ok: true };
});

/** （任意）招待取消 */
export const revokeInvite = functions.https.onCall(async (data, context) => {
  const uid = context.auth?.uid;
  if (!uid) throw new functions.https.HttpsError('unauthenticated', 'Sign in');
  const tenantId: string = data?.tenantId;
  const inviteId: string = data?.inviteId;
  if (!tenantId || !inviteId) throw new functions.https.HttpsError('invalid-argument', 'bad args');
  await assertTenantAdmin(tenantId, uid);
  await db.doc(`tenants/${tenantId}/invites/${inviteId}`).update({ status: 'revoked' });
  return { ok: true };
});