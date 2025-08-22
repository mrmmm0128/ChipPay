import * as functions from "firebase-functions";
import * as admin from "firebase-admin";
import Stripe from "stripe";
import * as dotenv from "dotenv";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { onDocumentWritten } from "firebase-functions/v2/firestore";
import { Resend } from "resend";
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

function calcApplicationFee(amount: number, feeCfg?: { percent?: number; fixed?: number }) {
  const p = Math.max(0, Math.min(100, Math.floor(feeCfg?.percent ?? 0))); // 0..100
  const f = Math.max(0, Math.floor(feeCfg?.fixed ?? 0));
  // JPY: 小数なし最小単位
  const percentPart = Math.floor((amount * p) / 100);
  return percentPart + f;
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

/** 認可: tenantId / role をトークンから取得（店舗用APIで使用） */
function requireAuthAndTenant(ctx: functions.https.CallableContext) {
  if (!ctx.auth) throw new functions.https.HttpsError("unauthenticated", "Sign in required");
  const tenantId = (ctx.auth.token as any).tenantId as string | undefined;
  const role = (ctx.auth.token as any).role as string | undefined;
  if (!tenantId) throw new functions.https.HttpsError("permission-denied", "No tenant");
  if (!role) throw new functions.https.HttpsError("permission-denied", "No role");
  return { tenantId, role };
}

/** 店舗が金額入力 → Checkout セッション発行（店舗用） */
export const createCheckoutSession =
  functions.region("us-central1")
  .runWith({ secrets: ["STRIPE_SECRET_KEY", "FRONTEND_BASE_URL"], memory: "256MB" })
  .https.onCall(async (data, ctx) => {
    const { tenantId } = requireAuthAndTenant(ctx);
    const { amount, currency = "JPY", memo = "" } = data as {
      amount: number; currency?: string; memo?: string;
    };

    if (!Number.isInteger(amount) || amount <= 0) {
      throw new functions.https.HttpsError("invalid-argument", "amount must be positive integer");
    }

    // テナントの稼働状態を確認
    const tDoc = await db.collection("tenants").doc(tenantId).get();
    if (!tDoc.exists || tDoc.data()!.status !== "active") {
      throw new functions.https.HttpsError("failed-precondition", "Tenant suspended or not found");
    }

    const FRONTEND_BASE_URL = requireEnv("FRONTEND_BASE_URL");
    const stripe = stripeClient();

    try {
      // Stripe Checkout Session 作成（Hosted）
      const session = await stripe.checkout.sessions.create({
        mode: "payment",
        payment_method_types: ["card", "link"],
        line_items: [
          {
            price_data: {
              currency,
              product_data: { name: `Order - ${tDoc.data()!.name}` },
              unit_amount: amount,
            },
            quantity: 1,
          },
        ],
        // Netlifyでも安全なハッシュ方式
        success_url: `${FRONTEND_BASE_URL}/#/payer?sid={CHECKOUT_SESSION_ID}`,
        cancel_url: `${FRONTEND_BASE_URL}/#/p?t=${tenantId}&canceled=true`,
        metadata: { tenantId, memo },
      });

      // Firestore にセッション保存
      await db.collection("paymentSessions").doc(session.id).set({
        tenantId,
        amount,
        currency,
        status: "pending",
        stripeCheckoutUrl: session.url,
        stripeSessionId: session.id,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        expiresAt: admin.firestore.Timestamp.fromMillis(Date.now() + 30 * 60 * 1000), // 30分
        memo,
      });

      return { checkoutUrl: session.url, sessionId: session.id };
    } catch (err: any) {
      // Stripe 由来の失敗をクライアントに分かりやすく返す
      throw new functions.https.HttpsError(
        "failed-precondition",
        err?.message || "Stripe error",
        { source: "stripe", code: err?.type || "stripe_error" }
      );
    }
  });

/** Stripe Webhook（rawBody を使って署名検証） */
// 既存：export const stripeWebhook = functions.region("us-central1")
// ↓↓↓ こう変える（SENDGRID_API_KEY を secrets に追加）
export const stripeWebhook =
  functions.region("us-central1")
    .runWith({
      secrets: [
        "STRIPE_SECRET_KEY",
        "STRIPE_WEBHOOK_SECRET",
        "STRIPE_CONNECT_WEBHOOK_SECRET",
        "FRONTEND_BASE_URL",
        "SENDGRID_API_KEY", // ★ ADD
        // MAIL_FROM / MAIL_FROM_NAME は Secret でも env でもOK。必要ならここに追加。
      ],
      memory: "256MB",
    })
      // （以下は既存と同じ）
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


/** 公開ページ（未ログイン）からのチップ用：Connect 宛先＋手数料対応 */
export const createTipSessionPublic =
  functions.region("us-central1")
    .runWith({
      secrets: ["STRIPE_SECRET_KEY", "FRONTEND_BASE_URL"],
      memory: "256MB",
    })
    .https.onCall(async (data, _ctx) => {
      const { tenantId, employeeId, amount, memo = "Tip" } = data as {
        tenantId?: string;
        employeeId?: string;
        amount?: number;
        memo?: string;
      };

      if (!tenantId || !employeeId) {
        throw new functions.https.HttpsError(
          "invalid-argument",
          "tenantId/employeeId required"
        );
      }
      if (!Number.isInteger(amount) || (amount ?? 0) <= 0 || (amount as number) > 1_000_000) {
        throw new functions.https.HttpsError("invalid-argument", "invalid amount");
      }

      // テナント状態
      const tRef = db.collection("tenants").doc(tenantId);
      const tDoc = await tRef.get();
      if (!tDoc.exists || tDoc.data()!.status !== "active") {
        throw new functions.https.HttpsError("failed-precondition", "Tenant suspended or not found");
      }

      // Stripe Connect 必須
      const acctId = tDoc.data()?.stripeAccountId as string | undefined;
      if (!acctId) {
        throw new functions.https.HttpsError("failed-precondition", "Store not connected to Stripe");
      }
      if (!tDoc.data()?.connect?.charges_enabled) {
        throw new functions.https.HttpsError("failed-precondition", "Store Stripe account is not ready (charges_disabled)");
      }

      // 従業員取得
      const eDoc = await tRef.collection("employees").doc(employeeId).get();
      if (!eDoc.exists) {
        throw new functions.https.HttpsError("not-found", "Employee not found");
      }
      const employeeName = (eDoc.data()?.name as string) ?? "Staff";

      const FRONTEND_BASE_URL = requireEnv("FRONTEND_BASE_URL");
      const stripe = stripeClient();

      // 手数料（無ければ 0 として処理）
      const feeCfg = (tDoc.data()?.fee ?? {}) as { percent?: number; fixed?: number };
      const appFee = calcApplicationFee(amount!, feeCfg);

      // 1) 事前にテナント配下の tips に pending 作成（docIDを metadata に持たせる）
      const tipRef = tRef.collection("tips").doc();
      await tipRef.set({
        tenantId,
        employeeId,
        amount,
        currency: "JPY", // Firestore上の表示用。Stripeには 'jpy' を渡す
        status: "pending",
        recipient: { type: "employee", employeeId, employeeName },
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      try {
        // 2) Stripe Checkout セッション作成（metadata に tipDocId 等を付与）
        const session = await stripe.checkout.sessions.create({
          mode: "payment",
          payment_method_types: ["card", "link"],
          line_items: [
            {
              price_data: {
                currency: "jpy", // Stripeは小文字
                product_data: { name: `Tip to ${employeeName}` },
                unit_amount: amount!, // JPY: 1円単位
              },
              quantity: 1,
            },
          ],
          success_url: `${FRONTEND_BASE_URL}/#/p?t=${tenantId}&thanks=true`,
          cancel_url: `${FRONTEND_BASE_URL}/#/p?t=${tenantId}&canceled=true`,
          metadata: {
            tenantId,
            employeeId,
            employeeName,         // 追加
            tipDocId: tipRef.id,  // 追加（WebhookでこのIDを優先して更新）
            tipType: "employee",
            memo,
          },
          payment_intent_data: {
            application_fee_amount: appFee,
            transfer_data: { destination: acctId },
          },
        });

        // （任意）セッションの記録もテナント配下に
        await tRef.collection("tipSessions").doc(session.id).set({
          status: "created",
          amount,
          employeeId,
          tipDocId: tipRef.id,
          stripeSessionId: session.id,
          stripeCheckoutUrl: session.url,
          feeApplied: appFee,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });

        return { checkoutUrl: session.url, sessionId: session.id, tipDocId: tipRef.id };
      } catch (err: any) {
        // 失敗時も pending のまま残る（必要なら削除/フラグ更新を検討）
        throw new functions.https.HttpsError(
          "failed-precondition",
          err?.message || "Stripe error",
          { source: "stripe", code: err?.type || "stripe_error" }
        );
      }
    });


    // 店舗向け：従業員IDなしでチップ用Checkoutを作成
export const createStoreTipSessionPublic =
  functions.region("us-central1")
    .runWith({
      secrets: ["STRIPE_SECRET_KEY", "FRONTEND_BASE_URL"],
      memory: "256MB",
    })
    .https.onCall(async (data, _ctx) => {
      const { tenantId, amount, memo = "Tip to store" } = data as {
        tenantId?: string;
        amount?: number;
        memo?: string;
      };

      // ====== 入力チェック ======
      if (!tenantId) {
        throw new functions.https.HttpsError(
          "invalid-argument",
          "tenantId required"
        );
      }
      if (
        !Number.isInteger(amount) ||
        (amount ?? 0) <= 0 ||
        (amount as number) > 1_000_000
      ) {
        throw new functions.https.HttpsError(
          "invalid-argument",
          "invalid amount"
        );
      }

      // ====== テナント・Stripe接続チェック ======
      const tSnap = await db.collection("tenants").doc(tenantId).get();
      if (!tSnap.exists || tSnap.data()!.status !== "active") {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "Tenant suspended or not found"
        );
      }
      const acctId = tSnap.data()?.stripeAccountId as string | undefined;
      if (!acctId) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "Store not connected to Stripe"
        );
      }
      const chargesEnabled = !!tSnap.data()?.connect?.charges_enabled;
      if (!chargesEnabled) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "Store Stripe account is not ready (charges_disabled)"
        );
      }

      // ====== Stripe Checkout セッション ======
      const stripe = stripeClient();
      const frontendBase = requireEnv("FRONTEND_BASE_URL");

      const currency = "jpy"; // JPY想定（最小単位で金額を渡す）
      const unitAmount = amount as number;

      const storeName = (tSnap.data()?.name as string | undefined) ?? tenantId;
      const title = memo || `Tip to store ${storeName}`;

      // プラットフォーム手数料を取りたい場合はここを設定
      const applicationFeeAmount = 0; // 例: Math.floor(unitAmount * 0.1);

      const session = await stripe.checkout.sessions.create({
        mode: "payment",
        payment_method_types: ["card"],
        line_items: [
          {
            price_data: {
              currency,
              product_data: { name: title },
              unit_amount: unitAmount,
            },
            quantity: 1,
          },
        ],
        success_url: `${frontendBase}/public/${tenantId}/thanks?sid={CHECKOUT_SESSION_ID}`,
        cancel_url: `${frontendBase}/public/${tenantId}`,
        // Webhook で「employeeId がない＝店舗チップ」分岐に入る想定
        metadata: {
          tenantId,
          kind: "store_tip",
        },
        payment_intent_data: {
          transfer_data: { destination: acctId },
          ...(applicationFeeAmount > 0
            ? { application_fee_amount: applicationFeeAmount }
            : {}),
        },
      });

      // 任意：セッションのプレ登録（Webhookでpaidに更新）
      await db.collection("paymentSessions").doc(session.id).set(
        {
          tenantId,
          amount: unitAmount,
          currency: currency.toUpperCase(),
          status: "pending",
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true }
      );

      await db
        .collection("tenants").doc(tenantId)
        .collection("tipSessions").doc(session.id)
        .set({
          tenantId,
          amount: unitAmount,
          currency: currency.toUpperCase(),
          status: "pending",
          kind: "store_tip",
          stripeCheckoutUrl: session.url,
          stripeSessionId: session.id,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });

      return { checkoutUrl: session.url };
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

/** tips ドキュメントを読んで、宛先と本文を組み立てて Resend で送信 */
async function sendTipNotificationWithResend(tenantId: string, tipId: string) {
  const db = admin.firestore();
  const tipRef = db.collection("tenants").doc(tenantId).collection("tips").doc(tipId);
  const tipSnap = await tipRef.get();
  if (!tipSnap.exists) return;

  const tip = tipSnap.data()!;
  const amount: number = (tip.amount as number) ?? 0;
  const currency = (tip.currency as string)?.toUpperCase() ?? "JPY";
  const recipient: any = tip.recipient ?? {};
  const isEmployee = recipient.type === "employee" || !!tip.employeeId;

  // ---- 宛先を決定 ----
  const to: string[] = [];
  if (isEmployee) {
    const empId = (tip.employeeId as string) ?? recipient.employeeId;
    if (empId) {
      const empSnap = await db.collection("tenants").doc(tenantId).collection("employees").doc(empId).get();
      const empEmail = empSnap.get("email") as string | undefined;
      if (empEmail) to.push(empEmail);
    }
  } else {
    const tenSnap = await db.collection("tenants").doc(tenantId).get();
    const notify = tenSnap.get("notificationEmails") as string[] | undefined; // 例: ['owner@ex.com']
    if (notify?.length) to.push(...notify);
  }
  // fallback（tipに直接メールが入っていたら使う）
  if (to.length === 0) {
    const fallback =
      (tip.employeeEmail as string | undefined) ||
      (recipient.employeeEmail as string | undefined) ||
      (tip.storeEmail as string | undefined);
    if (fallback) to.push(fallback);
  }
  if (to.length === 0) {
    console.warn("[Resend] no recipient found", { tenantId, tipId });
    return;
  }

  // ---- 表示用 ----
  const isJPY = currency === "JPY";
  const money = isJPY ? `¥${amount.toLocaleString("ja-JP")}` : `${amount} ${currency}`;
  const name = isEmployee
    ? (tip.employeeName ?? recipient.employeeName ?? "スタッフ")
    : (tip.storeName ?? recipient.storeName ?? "店舗");
  const memo = (tip.memo as string) || "";
  const createdAt: Date = tip.createdAt?.toDate?.() ?? new Date();
  const subject = isEmployee ? `チップを受け取りました: ${money}` : `店舗宛のチップ: ${money}`;
  const text = [
    `受取先: ${name}`,
    `金額: ${money}`,
    memo ? `メモ: ${memo}` : "",
    `日時: ${createdAt.toLocaleString("ja-JP")}`,
  ].filter(Boolean).join("\n");
  const html = `
  <div style="font-family: system-ui, -apple-system, Segoe UI, Roboto, Helvetica, Arial; line-height:1.6; color:#111">
    <h2 style="margin:0 0 12px">🎉 ${escapeHtml(subject)}</h2>
    <p style="margin:0 0 6px">受取先：<strong>${escapeHtml(name)}</strong></p>
    <p style="margin:0 0 6px">金額：<strong>${escapeHtml(money)}</strong></p>
    ${memo ? `<p style="margin:0 0 6px">メモ：${escapeHtml(memo)}</p>` : ""}
    <p style="margin:0 0 6px">日時：${createdAt.toLocaleString("ja-JP")}</p>
  </div>`;

  // ---- Resend 送信 ----
  const apiKey = process.env.RESEND_API_KEY;
  if (!apiKey) {
    console.warn("[Resend] missing RESEND_API_KEY, skip email");
    return;
  }
  const resend = new Resend(apiKey);
  await resend.emails.send({
    from: "YourPay 通知 <notify@appfromkomeda.jp>", // ★ Resendで認証済みの差出人に変更
    to,
    subject,
    text,
    html,
  });

  await tipRef.set(
    { notification: { emailedAt: admin.firestore.FieldValue.serverTimestamp(), to } },
    { merge: true }
  );
}

function escapeHtml(s: string) {
  return s.replace(/[&<>'"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", "\"": "&quot;" }[c]!));
}

export const onTipSucceededSendMail = onDocumentWritten(
  {
    region: "us-central1",
    document: "tenants/{tenantId}/tips/{tipId}",
    secrets: ["RESEND_API_KEY"], // ← これでこの関数にだけ秘密が注入される
  },
  async (event) => {
    const before = event.data?.before.data() as any | undefined;
    const after  = event.data?.after.data()  as any | undefined;
    if (!after) return;

    const beforeStatus = before?.status;
    const afterStatus  = after?.status;

    // 「succeeded になった瞬間」だけ送る（重複送信防止）
    if (afterStatus !== "succeeded" || beforeStatus === "succeeded") return;

    const { tenantId, tipId } = event.params;
    try {
      await sendTipNotificationWithResend(tenantId, tipId);
    } catch (e) {
      console.error("[Resend] sendTipNotification error", e);
    }
  }
);






// 他ファイルの関数もまとめてエクスポート
export * from "./setUserClaims";
