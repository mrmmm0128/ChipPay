/* eslint-disable @typescript-eslint/no-explicit-any */
import * as functions from "firebase-functions";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { onDocumentWritten } from "firebase-functions/v2/firestore";
import { defineSecret } from "firebase-functions/params";
import * as admin from "firebase-admin";
import Stripe from "stripe";
import * as crypto from "crypto";

if (!admin.apps.length) admin.initializeApp();
const db = admin.firestore();

/* ===================== Secrets / Const ===================== */
export const RESEND_API_KEY = defineSecret("RESEND_API_KEY");
const APP_ORIGIN = "https://venerable-mermaid-fcf8c8.netlify.app";


/* ===================== Utils ===================== */
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

function calcApplicationFee(
  amount: number,
  feeCfg?: { percent?: number; fixed?: number }
) {
  const p = Math.max(0, Math.min(100, Math.floor(feeCfg?.percent ?? 0)));
  const f = Math.max(0, Math.floor(feeCfg?.fixed ?? 0));
  const percentPart = Math.floor((amount * p) / 100);
  return percentPart + f;
}

let _stripe: Stripe | null = null;
function stripeClient(): Stripe {
  if (_stripe) return _stripe;
  _stripe = new Stripe(requireEnv("STRIPE_SECRET_KEY"), {
    apiVersion: "2023-10-16",
  });
  return _stripe!;
}

function sha256(s: string) {
  return crypto.createHash("sha256").update(s).digest("hex");
}

function escapeHtml(s: string) {
  return s.replace(/[&<>'"]/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" } as any)[c]!
  );
}

/* ===================== UID 名前空間 ヘルパー ===================== */
/**
 * tenantIndex/{tenantId} => { uid, tenantId, stripeAccountId? }
 * tenantStripeIndex/{tenantId} => { uid, tenantId, stripeAccountId }
 */
type TenantIndexDoc = {
  uid: string;
  tenantId: string;
  stripeAccountId?: string;
};

function tenantRefByUid(uid: string, tenantId: string) {
  return db.collection(uid).doc(tenantId);
}

async function tenantRefByIndex(tenantId: string) {
  const idx = await db.collection("tenantIndex").doc(tenantId).get();
  if (!idx.exists) throw new Error(`tenantIndex not found for ${tenantId}`);
  const { uid } = idx.data() as TenantIndexDoc;
  return tenantRefByUid(uid, tenantId);
}

async function tenantRefByStripeAccount(acctId: string) {
  const qs = await db
    .collection("tenantStripeIndex")
    .where("stripeAccountId", "==", acctId)
    .limit(1)
    .get();
  if (qs.empty) throw new Error("tenantStripeIndex not found");
  const { uid, tenantId } = qs.docs[0].data() as TenantIndexDoc;
  return tenantRefByUid(uid, tenantId);
}

async function upsertTenantIndex(
  uid: string,
  tenantId: string,
  stripeAccountId?: string
) {
  await db.collection("tenantIndex").doc(tenantId).set(
    {
      uid,
      tenantId,
      ...(stripeAccountId ? { stripeAccountId } : {}),
    },
    { merge: true }
  );
  if (stripeAccountId) {
    await db
      .collection("tenantStripeIndex")
      .doc(tenantId)
      .set({ uid, tenantId, stripeAccountId }, { merge: true });
  }
}

/* ===================== Firestore ルール系 ===================== */
async function assertTenantAdmin(tenantId: string, uid: string) {
  const mem = await db.doc(`tenants/${tenantId}/members/${uid}`).get();
  if (mem.exists && mem.data()?.role === "admin") return;
  const t = await db.doc(`tenants/${tenantId}`).get();
  const arr: string[] = (t.data()?.memberUids || []) as string[];
  if (arr.includes(uid)) return;
  throw new functions.https.HttpsError("permission-denied", "Not tenant admin");
}

/* ===================== 計算補助 ===================== */
type DeductionRule = {
  percent: number;
  fixed: number;
  effectiveFrom?: FirebaseFirestore.Timestamp | null;
};

async function pickEffectiveRule(tenantId: string, at: Date): Promise<DeductionRule> {
  // NOTE: こちらは旧 tenants/{tenantId} 階層の履歴。UID 名空間へ移行しない（履歴の置き場所が異なるなら調整）
  const histSnap = await db
    .collection("tenants")
    .doc(tenantId)
    .collection("storeDeductionHistory")
    .where("effectiveFrom", "<=", admin.firestore.Timestamp.fromDate(at))
    .orderBy("effectiveFrom", "desc")
    .limit(1)
    .get();

  if (!histSnap.empty) {
    const d = histSnap.docs[0].data();
    return {
      percent: Number(d.percent ?? 0),
      fixed: Number(d.fixed ?? 0),
      effectiveFrom: d.effectiveFrom ?? null,
    };
  }

  const cur = await db.collection("tenants").doc(tenantId).get();
  const sd = (cur.data()?.storeDeduction as any) ?? {};
  return {
    percent: Number(sd.percent ?? 0),
    fixed: Number(sd.fixed ?? 0),
    effectiveFrom: null,
  };
}

function splitMinor(amountMinor: number, percent: number, fixedMinor: number) {
  const percentPart = Math.floor(amountMinor * (Math.max(0, percent) / 100));
  const store = Math.min(
    Math.max(0, amountMinor),
    Math.max(0, percentPart + Math.max(0, fixedMinor))
  );
  const staff = amountMinor - store;
  return { storeAmount: store, staffAmount: staff };
}

/* ===================== プラン取得 / 顧客確保 ===================== */
type Plan = { stripePriceId: string; name?: string; feePercent?: number };
type TenantSubscription = {
  plan?: string;
  status?: string;
  feePercent?: number;
  stripeCustomerId?: string;
  stripeSubscriptionId?: string;
  currentPeriodEnd?: admin.firestore.Timestamp;
};

async function getPlanFromDb(planId: string): Promise<Plan> {
  let snap = await db.collection("billingPlans").doc(planId).get();
  if (snap.exists) return snap.data() as Plan;

  snap = await db.collection("billing").doc("plans").get();
  if (snap.exists) {
    const data = snap.data() || {};
    const candidate = (data.plans && data.plans[planId]) || data[planId];
    if (candidate?.stripePriceId) return candidate as Plan;
  }

  snap = await db.collection("billing").doc("plans").collection("plans").doc(planId).get();
  if (snap.exists) return snap.data() as Plan;

  throw new functions.https.HttpsError(
    "not-found",
    `Plan "${planId}" not found in billingPlans/{id}, billing/plans(plans map), or billing/plans/plans/{id}.`
  );
}

async function ensureCustomer(
  uid: string,
  tenantId: string,
  email?: string,
  name?: string
): Promise<string> {
  const stripe = new Stripe(requireEnv("STRIPE_SECRET_KEY"), {
    apiVersion: "2023-10-16",
  });
  const tenantRef = tenantRefByUid(uid, tenantId);
  const tSnap = await tenantRef.get();
  const tData = (tSnap.data() || {}) as { subscription?: TenantSubscription };

  const sub = tData.subscription || {};
  if (sub.stripeCustomerId) return sub.stripeCustomerId;

  const customer = await stripe.customers.create({
    email,
    name,
    metadata: { tenantId, uid },
  });

  await tenantRef.set(
    { subscription: { ...(sub || {}), stripeCustomerId: customer.id } },
    { merge: true }
  );

  // index の担保
  await upsertTenantIndex(uid, tenantId);
  return customer.id;
}

/* ============================================================
 *  公開ページ: チップ（スタッフ宛）
 *  ※ uid 不明 → tenantIndex から逆引き
 * ==========================================================*/
export const createTipSessionPublic = functions
  .region("us-central1")
  .runWith({
    secrets: ["STRIPE_SECRET_KEY", "FRONTEND_BASE_URL"],
    memory: "256MB",
  })
  .https.onCall(async (data) => {
    const { tenantId, employeeId, amount, memo = "Tip" } = data as {
      tenantId?: string;
      employeeId?: string;
      amount?: number;
      memo?: string;
    };

    if (!tenantId || !employeeId) {
      throw new functions.https.HttpsError("invalid-argument", "tenantId/employeeId required");
    }
    if (!Number.isInteger(amount) || (amount ?? 0) <= 0 || (amount as number) > 1_000_000) {
      throw new functions.https.HttpsError("invalid-argument", "invalid amount");
    }

    // uid を逆引きして uid/{tenantId} を参照
    const tRef = await tenantRefByIndex(tenantId);
    const tDoc = await tRef.get();
    if (!tDoc.exists || tDoc.data()!.status !== "active") {
      throw new functions.https.HttpsError("failed-precondition", "Tenant suspended or not found");
    }

    const acctId = tDoc.data()?.stripeAccountId as string | undefined;
    if (!acctId) {
      throw new functions.https.HttpsError("failed-precondition", "Store not connected to Stripe");
    }
    if (!tDoc.data()?.connect?.charges_enabled) {
      throw new functions.https.HttpsError("failed-precondition", "Store Stripe account is not ready (charges_disabled)");
    }

    const eDoc = await tRef.collection("employees").doc(employeeId).get();
    if (!eDoc.exists) {
      throw new functions.https.HttpsError("not-found", "Employee not found");
    }
    const employeeName = (eDoc.data()?.name as string) ?? "Staff";

    const sub = (tDoc.data()?.subscription ?? {}) as { plan?: string; feePercent?: number };
    const plan = (sub.plan ?? "A").toUpperCase();
    const percent = typeof sub.feePercent === "number"
      ? sub.feePercent
      : plan === "B" ? 15 : plan === "C" ? 10 : 20;

    const appFee = calcApplicationFee(amount!, { percent, fixed: 0 });

    const tipRef = tRef.collection("tips").doc();
    await tipRef.set({
      tenantId,
      employeeId,
      amount,
      currency: "JPY",
      status: "pending",
      recipient: { type: "employee", employeeId, employeeName },
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    const stripe = stripeClient();
    const FRONTEND_BASE_URL = requireEnv("FRONTEND_BASE_URL");

    const session = await stripe.checkout.sessions.create({
      mode: "payment",
      payment_method_types: ["card", "link"],
      line_items: [
        {
          price_data: {
            currency: "jpy",
            product_data: { name: `Tip to ${employeeName}` },
            unit_amount: amount!,
          },
          quantity: 1,
        },
      ],
      success_url: `${FRONTEND_BASE_URL}/#/p?t=${tenantId}&thanks=true`,
      cancel_url: `${FRONTEND_BASE_URL}/#/p?t=${tenantId}&canceled=true`,
      metadata: {
        tenantId,
        employeeId,
        employeeName,
        tipDocId: tipRef.id,
        tipType: "employee",
        memo,
        feePercentApplied: String(percent),
      },
      payment_intent_data: {
        application_fee_amount: appFee,
        transfer_data: { destination: acctId },
      },
    });

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
  });

/* ============================================================
 *  公開ページ: チップ（店舗宛）
 *  ※ uid 不明 → tenantIndex から逆引き
 * ==========================================================*/
export const createStoreTipSessionPublic = functions
  .region("us-central1")
  .runWith({
    secrets: ["STRIPE_SECRET_KEY", "FRONTEND_BASE_URL"],
    memory: "256MB",
  })
  .https.onCall(async (data) => {
    const { tenantId, amount, memo = "Tip to store" } = data as {
      tenantId?: string;
      amount?: number;
      memo?: string;
    };

    if (!tenantId) {
      throw new functions.https.HttpsError("invalid-argument", "tenantId required");
    }
    if (!Number.isInteger(amount) || (amount ?? 0) <= 0 || (amount as number) > 1_000_000) {
      throw new functions.https.HttpsError("invalid-argument", "invalid amount");
    }

    const tRef = await tenantRefByIndex(tenantId);
    const tDoc = await tRef.get();
    if (!tDoc.exists || tDoc.data()!.status !== "active") {
      throw new functions.https.HttpsError("failed-precondition", "Tenant suspended or not found");
    }

    const acctId = tDoc.data()?.stripeAccountId as string | undefined;
    if (!acctId) {
      throw new functions.https.HttpsError("failed-precondition", "Store not connected to Stripe");
    }
    const chargesEnabled = !!tDoc.data()?.connect?.charges_enabled;
    if (!chargesEnabled) {
      throw new functions.https.HttpsError("failed-precondition", "Store Stripe account is not ready (charges_disabled)");
    }

    const sub = (tDoc.data()?.subscription ?? {}) as { plan?: string; feePercent?: number };
    const plan = (sub.plan ?? "A").toUpperCase();
    const percent = typeof sub.feePercent === "number"
      ? sub.feePercent
      : plan === "B" ? 15 : plan === "C" ? 10 : 20;

    const appFee = calcApplicationFee(amount!, { percent, fixed: 0 });
    const storeName = (tDoc.data()?.name as string | undefined) ?? tenantId;

    // uid を取得（親コレクション名 = uid）
    const uid = tRef.parent!.id;

    const tipRef = tRef.collection("tips").doc();
    await tipRef.set({
      tenantId,
      amount,
      currency: "JPY",
      status: "pending",
      recipient: { type: "store", storeName },
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    const stripe = stripeClient();
    const FRONTEND_BASE_URL = requireEnv("FRONTEND_BASE_URL");

    const currency = "jpy";
    const unitAmount = amount as number;
    const title = memo || `Tip to store ${storeName}`;

    const session = await stripe.checkout.sessions.create({
      mode: "payment",
      payment_method_types: ["card", "link"],
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
      success_url: `${FRONTEND_BASE_URL}/#/p?t=${tenantId}&thanks=true`,
      cancel_url: `${FRONTEND_BASE_URL}/#/p?t=${tenantId}&canceled=true`,
      metadata: {
        tenantId,
        tipDocId: tipRef.id,
        tipType: "store",
        storeName,
        memo,
        feePercentApplied: String(percent),
      },
      payment_intent_data: {
        transfer_data: { destination: acctId },
        application_fee_amount: appFee,
      },
    });

    await db
      .collection(uid)
      .doc(tenantId)
      .collection("tipSessions")
      .doc(session.id)
      .set(
        {
          tenantId,
          amount: unitAmount,
          currency: currency.toUpperCase(),
          status: "created",
          kind: "store_tip",
          tipDocId: tipRef.id,
          stripeCheckoutUrl: session.url,
          stripeSessionId: session.id,
          feeApplied: appFee,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true }
      );

    return { checkoutUrl: session.url, sessionId: session.id, tipDocId: tipRef.id };
  });

/* ===================== チップ成功メール（既存: uid/{tenantId}/tips） ===================== */
export const onTipSucceededSendMailV2 = onDocumentWritten(
  {
    region: "us-central1",
    document: "{uid}/{tenantId}/tips/{tipId}",
    secrets: [RESEND_API_KEY],
    memory: "256MiB",
    maxInstances: 10,
  },
  async (event) => {
    const before = event.data?.before?.data() as any | undefined;
    const after = event.data?.after?.data() as any | undefined;
    if (!after) return;

    const beforeStatus = before?.status;
    const afterStatus = after?.status;
    if (afterStatus !== "succeeded" || beforeStatus === "succeeded") return;

    await sendTipNotification(
      event.params.tenantId,
      event.params.tipId,
      RESEND_API_KEY.value(),
      event.params.uid
    );
  }
);

async function sendTipNotification(
  tenantId: string,
  tipId: string,
  resendApiKey: string,
  uid: string
) {
  const tipRef = db.collection(uid).doc(tenantId).collection("tips").doc(tipId);
  const tipSnap = await tipRef.get();
  if (!tipSnap.exists) return;

  const tip = tipSnap.data()!;
  const amount: number = (tip.amount as number) ?? 0;
  const currency = (tip.currency as string)?.toUpperCase() ?? "JPY";
  const recipient: any = tip.recipient ?? {};
  const isEmployee = recipient.type === "employee" || !!tip.employeeId;

  const to: string[] = [];
  if (isEmployee) {
    const empId = (tip.employeeId as string) ?? recipient.employeeId;
    if (empId) {
      const empSnap = await db
        .collection(uid)
        .doc(tenantId)
        .collection("employees")
        .doc(empId)
        .get();
      const empEmail = empSnap.get("email") as string | undefined;
      if (empEmail) to.push(empEmail);
    }
  } else {
    const tenSnap = await db.collection(uid).doc(tenantId).get();
    const notify = tenSnap.get("notificationEmails") as string[] | undefined;
    if (notify?.length) to.push(...notify);
  }
  if (to.length === 0) {
    const fallback =
      (tip.employeeEmail as string | undefined) ||
      (recipient.employeeEmail as string | undefined) ||
      (tip.storeEmail as string | undefined);
    if (fallback) to.push(fallback);
  }
  if (to.length === 0) {
    console.warn("[tip mail] no recipient", { tenantId, tipId });
    return;
  }

  const isJPY = currency === "JPY";
  const money = isJPY ? `¥${amount.toLocaleString("ja-JP")}` : `${amount} ${currency}`;
  const name = isEmployee
    ? tip.employeeName ?? recipient.employeeName ?? "スタッフ"
    : tip.storeName ?? recipient.storeName ?? "店舗";
  const memo = (tip.memo as string) || "";
  const createdAt: Date = tip.createdAt?.toDate?.() ?? new Date();

  const subject = isEmployee ? `チップを受け取りました: ${money}` : `店舗宛のチップ: ${money}`;
  const text = [
    `受取先: ${name}`,
    `金額: ${money}`,
    memo ? `メモ: ${memo}` : "",
    `日時: ${createdAt.toLocaleString("ja-JP")}`,
  ]
    .filter(Boolean)
    .join("\n");

  const html = `
  <div style="font-family: system-ui, -apple-system, Segoe UI, Roboto, Helvetica, Arial; line-height:1.6; color:#111">
    <h2 style="margin:0 0 12px">🎉 ${subject}</h2>
    <p style="margin:0 0 6px">受取先：<strong>${escapeHtml(name)}</strong></p>
    <p style="margin:0 0 6px">金額：<strong>${escapeHtml(money)}</strong></p>
    ${memo ? `<p style="margin:0 0 6px">メモ：${escapeHtml(memo)}</p>` : ""}
    <p style="margin:0 0 6px">日時：${createdAt.toLocaleString("ja-JP")}</p>
  </div>`;

  const { Resend } = await import("resend");
  const resend = new Resend(resendApiKey);

  await resend.emails.send({
    from: "YourPay 通知 <sendtip_app@appfromkomeda.jp>",
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

/* ===================== Stripe Webhook ===================== */
export const stripeWebhook = functions
  .region("us-central1")
  .runWith({
    secrets: [
      "STRIPE_SECRET_KEY",
      "STRIPE_WEBHOOK_SECRET",
      "STRIPE_CONNECT_WEBHOOK_SECRET",
      "FRONTEND_BASE_URL",
      "STRIPE_PAYMENT_WEBHOOK_SECRET"
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
    const secrets = [
      process.env.STRIPE_WEBHOOK_SECRET,
      process.env.STRIPE_CONNECT_WEBHOOK_SECRET,
    ].filter(Boolean) as string[];

    let event: Stripe.Event | null = null;
    for (const secret of secrets) {
      try {
        event = stripe.webhooks.constructEvent(
          (req as any).rawBody,
          sig,
          secret
        );
        break;
      } catch {
        // try next secret
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
      /* ========== 1) Checkout 完了 ========== */
      if (type === "checkout.session.completed") {
        const session = event.data.object as Stripe.Checkout.Session;

        // A. サブスク
        if (session.mode === "subscription") {
          const tenantId = session.metadata?.tenantId as string | undefined;
          const uidMeta = session.metadata?.uid as string | undefined;
          const plan = session.metadata?.plan as string | undefined;
          const subscriptionId = session.subscription as string | undefined;
          const customerId = (session.customer as string | undefined) ?? undefined;

          if (!tenantId || !subscriptionId) {
            console.error("subscription checkout completed but missing tenantId or subscriptionId");
          } else {
            const sub = await stripe.subscriptions.retrieve(subscriptionId);

            let feePercent: number | undefined;
if (plan) {
  // ここを修正：billingPlans/{planId} から取得
  const planSnap = await db.collection("billingPlans").doc(String(plan)).get();
  feePercent = planSnap.exists
    ? (planSnap.data()?.feePercent as number | undefined)
    : undefined;
}


            // uid の確定（meta 優先 → index）
            let uid = uidMeta;
            if (!uid) {
              const tRefIdx = await tenantRefByIndex(tenantId);
              uid = tRefIdx.parent!.id;
            }
            const tRef = tenantRefByUid(uid!, tenantId);

            await tRef.set(
              {
                subscription: {
                  plan,
                  status: sub.status,
                
                  stripeCustomerId: customerId,
                  stripeSubscriptionId: sub.id,
                  currentPeriodEnd: admin.firestore.Timestamp.fromMillis(sub.current_period_end * 1000),
                  ...(typeof feePercent === "number" ? { feePercent } : {}),
                },
              },
              { merge: true }
            );
          }

          await docRef.set({ handled: true }, { merge: true });
          res.sendStatus(200);
          return;
        }

        // B. 初期費用（mode=payment & kind=initial_fee）
        if (session.mode === "payment") {
          let tenantId =
            (session.metadata?.tenantId as string | undefined) ??
            (session.client_reference_id as string | undefined);

          let uidMeta = session.metadata?.uid as string | undefined;

          let isInitialFee = false;
          const paymentIntentId = session.payment_intent as string | undefined;
          if (paymentIntentId) {
            const pi = await stripe.paymentIntents.retrieve(paymentIntentId);
            const kind =
              (pi.metadata?.kind as string | undefined) ??
              (session.metadata?.kind as string | undefined);
            if (!tenantId) tenantId = pi.metadata?.tenantId as string | undefined;
            if (!uidMeta) uidMeta = pi.metadata?.uid as string | undefined;
            isInitialFee = kind === "initial_fee";
          }

          if (isInitialFee && tenantId) {
            let uid = uidMeta;
            if (!uid) {
              const tRefIdx = await tenantRefByIndex(tenantId);
              uid = tRefIdx.parent!.id;
            }
            const tRef = tenantRefByUid(uid!, tenantId);

            await tRef.set(
              {
                initialFee: {
                  status: "paid",
                  amount: session.amount_total ?? 0,
                  currency: (session.currency ?? "jpy").toUpperCase(),
                  stripePaymentIntentId: paymentIntentId ?? null,
                  stripeCheckoutSessionId: session.id,
                  paidAt: admin.firestore.FieldValue.serverTimestamp(),
                  updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                },
              },
              { merge: true }
            );

            await docRef.set({ handled: true }, { merge: true });
            res.sendStatus(200);
            return;
          }
        }

        // C. チップ（mode=payment の通常ルート）
        const sid = session.id;
        const tenantIdMeta = session.metadata?.tenantId as string | undefined;
        const employeeId = session.metadata?.employeeId as string | undefined;
        let employeeName = session.metadata?.employeeName as string | undefined;
        const payIntentId = session.payment_intent as string | undefined;
        let uid = session.metadata?.uid as string | undefined;

        const stripeCreatedSec =
          (session.created as number | undefined) ?? (event.created as number);
        const createdAtTs = admin.firestore.Timestamp.fromMillis(
          (stripeCreatedSec ?? Math.floor(Date.now() / 1000)) * 1000
        );

        if (!tenantIdMeta) {
          console.error("checkout.session.completed: missing tenantId in metadata");
        } else {
          if (!uid) {
            const tRefIdx = await tenantRefByIndex(tenantIdMeta);
            uid = tRefIdx.parent!.id;
          }
          const tRef = tenantRefByUid(uid!, tenantIdMeta);

          const tipDocId =
            (session.metadata?.tipDocId as string | undefined) || payIntentId || sid;

          let storeName = session.metadata?.storeName as string | undefined;
          if (!storeName) {
            const tSnap = await tRef.get();
            storeName = (tSnap.exists && (tSnap.data()?.name as string)) || "Store";
          }

          if (employeeId && !employeeName) {
            const eSnap = await tRef.collection("employees").doc(employeeId).get();
            employeeName = (eSnap.exists && (eSnap.data()?.name as string)) || "Staff";
          }

          const recipient = employeeId
            ? { type: "employee", employeeId, employeeName: employeeName || "Staff" }
            : { type: "store", storeName: storeName! };

          const tipRef = tRef.collection("tips").doc(tipDocId);
          const tipSnap = await tipRef.get();
          const existingCreatedAt = tipSnap.exists ? tipSnap.data()?.createdAt : null;

          await tipRef.set(
            {
              tenantId: tenantIdMeta,
              sessionId: sid,
              amount: session.amount_total ?? 0,
              currency: (session.currency ?? "jpy").toUpperCase(),
              status: "succeeded",
              stripePaymentIntentId: payIntentId ?? "",
              recipient,
              updatedAt: admin.firestore.FieldValue.serverTimestamp(),
              createdAt: existingCreatedAt ?? createdAtTs,
            },
            { merge: true }
          );

          const tipAfter = await tipRef.get();
          const alreadySplit = !!tipAfter.data()?.split?.storeAmount;
          if (!alreadySplit) {
            const eff = await pickEffectiveRule(tenantIdMeta, createdAtTs.toDate());
            const totalMinor = (session.amount_total ?? 0) as number;
            const { storeAmount, staffAmount } = splitMinor(
              totalMinor,
              eff.percent,
              eff.fixed
            );

            await tipRef.set(
              {
                split: {
                  percentApplied: eff.percent,
                  fixedApplied: eff.fixed,
                  effectiveFrom: eff.effectiveFrom ?? null,
                  computedAt: admin.firestore.FieldValue.serverTimestamp(),
                  storeAmount,
                  staffAmount,
                },
              },
              { merge: true }
            );
          }

          try {
            if (payIntentId) {
              const pi = await stripe.paymentIntents.retrieve(payIntentId, {
                expand: ["latest_charge.balance_transaction"],
              });
              const latestCharge = (pi.latest_charge as Stripe.Charge | null) || null;
              const bt =
                latestCharge?.balance_transaction as
                  | Stripe.BalanceTransaction
                  | undefined;

              const stripeFee = bt?.fee ?? 0;
              const stripeFeeCurrency =
                bt?.currency?.toUpperCase() ??
                (session.currency ?? "jpy").toUpperCase();

              const appFeeAmount = latestCharge?.application_fee_amount ?? 0;

              const splitNow = (await tipRef.get()).data()?.split ?? {};
              const storeCut = (splitNow.storeAmount as number | undefined) ?? 0;

              const gross = (session.amount_total ?? 0) as number;
              const isStaff = !!employeeId;

              const toStore = isStaff
                ? storeCut
                : Math.max(0, gross - appFeeAmount - stripeFee);
              const toStaff = isStaff
                ? Math.max(0, gross - appFeeAmount - stripeFee - storeCut)
                : 0;

              await tipRef.set(
                {
                  fees: {
                    platform: appFeeAmount,
                    stripe: {
                      amount: stripeFee,
                      currency: stripeFeeCurrency,
                      balanceTransactionId: bt?.id ?? null,
                    },
                  },
                  net: {
                    toStore: toStore,
                    toStaff: toStaff,
                  },
                  feesComputedAt: admin.firestore.FieldValue.serverTimestamp(),
                },
                { merge: true }
              );
            }
          } catch (err) {
            console.error("Failed to enrich tip with stripe fee:", err);
          }
        }
      }

      /* ========== 2) Checkout その他 ========== */
      if (type === "checkout.session.expired" || type === "checkout.session.async_payment_failed") {
        const session = event.data.object as Stripe.Checkout.Session;
        const tenantId = session.metadata?.tenantId as string | undefined;
        if (tenantId) {
          let uid = session.metadata?.uid as string | undefined;
          if (!uid) {
            const tRefIdx = await tenantRefByIndex(tenantId);
            uid = tRefIdx.parent!.id;
          }
          await tenantRefByUid(uid!, tenantId)
            .collection("tipSessions")
            .doc(session.id)
            .set(
              {
                status: type.endsWith("failed") ? "failed" : "expired",
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
              },
              { merge: true }
            );
        }
      }

     
/* ========== 3) 購読の作成/更新 ========== */
if (type === "customer.subscription.created" || type === "customer.subscription.updated") {
  const sub = event.data.object as Stripe.Subscription;

  // Subscription の metadata から取得（← session は使えない）
  let tenantId = sub.metadata?.tenantId as string | undefined;
  let uid      = sub.metadata?.uid as string | undefined;
  const plan   = sub.metadata?.plan as string | undefined;

  if (!tenantId) {
    console.error("[sub.created/updated] missing tenantId in subscription.metadata", { subId: sub.id });
    await docRef.set({ handled: true }, { merge: true });
    res.sendStatus(200);
    return;
  }

  // uid が無ければ tenantIndex から逆引き
  if (!uid) {
    const tRefIdx = await tenantRefByIndex(tenantId);
    uid = tRefIdx.parent!.id; // 親コレクション名 = uid
  }

  // トライアル情報
  const isTrialing = sub.status === "trialing";
  const trialStart = sub.trial_start
    ? admin.firestore.Timestamp.fromMillis(sub.trial_start * 1000)
    : null;
  const trialEnd = sub.trial_end
    ? admin.firestore.Timestamp.fromMillis(sub.trial_end * 1000)
    : null;

  // プランごとの手数料（必要なら）
  let feePercent: number | undefined;
if (plan) {
  // ここを修正：billingPlans/{planId} から取得
  const planSnap = await db.collection("billingPlans").doc(String(plan)).get();
  feePercent = planSnap.exists
    ? (planSnap.data()?.feePercent as number | undefined)
    : undefined;
}


  // uid/{tenantId} に保存（あなたの読み先と統一）
  await tenantRefByUid(uid!, tenantId).set(
    {
      subscription: {
        plan,
        status: sub.status,
        stripeCustomerId: (sub.customer as string) ?? undefined,
        stripeSubscriptionId: sub.id,
        currentPeriodEnd: admin.firestore.Timestamp.fromMillis(sub.current_period_end * 1000),
        trial: {
          status: isTrialing ? "trialing" : "none",
          trialStart,
          trialEnd,
        },
        ...(typeof feePercent === "number" ? { feePercent } : {}),
      },
    },
    { merge: true }
  );

  // トライアル終了直後に再トライアル防止フラグを付与
  try {
    if (sub.status === "active" && sub.trial_end && sub.trial_end * 1000 <= Date.now()) {
      await stripe.customers.update(sub.customer as string, {
        metadata: { zotman_trial_used: "true" },
      });
    }
  } catch (e) {
    console.warn("Failed to set zotman_trial_used on customer:", e);
  }

  await docRef.set({ handled: true }, { merge: true });
  res.sendStatus(200);
  return;
}

      if (type === "customer.subscription.deleted") {
        const sub = event.data.object as Stripe.Subscription;
        const tenantId = sub.metadata?.tenantId as string | undefined;
        let uid = sub.metadata?.uid as string | undefined;

        if (tenantId) {
          if (!uid) {
            const tRefIdx = await tenantRefByIndex(tenantId);
            uid = tRefIdx.parent!.id;
          }
          await tenantRefByUid(uid!, tenantId).set(
            {
              subscription: {
                status: "canceled",
                stripeSubscriptionId: sub.id,
                currentPeriodEnd: admin.firestore.Timestamp.fromMillis(sub.current_period_end * 1000),
              },
            },
            { merge: true }
          );
        }
      }

      /* ========== 4) 請求書 ========== */
if (type === "invoice.payment_succeeded" || type === "invoice.payment_failed") {
  const inv = event.data.object as Stripe.Invoice;
  const customerId = inv.customer as string;

  // 追加: トライアル明け最初の課金を検出 → Customerにフラグ
  try {
    if (
      type === "invoice.payment_succeeded" &&
      inv.paid &&
      inv.billing_reason === "subscription_cycle" && // トライアル明け最初の定期請求など
      inv.subscription
    ) {
      const sub = await stripe.subscriptions.retrieve(inv.subscription as string);
      // trial_end が支払時刻以前 = もうトライアルではない
      if (sub.trial_end && sub.trial_end * 1000 <= Date.now()) {
        await stripe.customers.update(customerId, {
          metadata: { zotman_trial_used: "true" },
        });
      }
    }
  } catch (e) {
    console.warn("Failed to mark zotman_trial_used on invoice.payment_succeeded:", e);
  }

  // === 既存のテナント検索・invoices 保存ロジック（そのまま） ===
  const idxSnap = await db.collection("tenantIndex").get();
  for (const d of idxSnap.docs) {
    const { uid, tenantId } = d.data() as TenantIndexDoc;
    const t = await db.collection(uid).doc(tenantId).get();
    if (t.exists && t.get("subscription.stripeCustomerId") === customerId) {
      await db
        .collection(uid)
        .doc(tenantId)
        .collection("invoices")
        .doc(inv.id)
        .set(
          {
            amount_due: inv.amount_due,
            amount_paid: inv.amount_paid,
            currency: (inv.currency ?? "jpy").toUpperCase(),
            status: inv.status,
            hosted_invoice_url: inv.hosted_invoice_url,
            invoice_pdf: inv.invoice_pdf,
            created: admin.firestore.Timestamp.fromMillis(inv.created * 1000),
            period_start: admin.firestore.Timestamp.fromMillis(
              ((inv.lines?.data?.[0]?.period?.start ?? inv.created) as number) * 1000
            ),
            period_end: admin.firestore.Timestamp.fromMillis(
              ((inv.lines?.data?.[0]?.period?.end ?? inv.created) as number) * 1000
            ),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
          { merge: true }
        );
      break;
    }
  }
}


      /* ========== 5) Connect アカウント状態 ========== */
      if (type === "account.updated") {
        const acct = event.data.object as Stripe.Account;
        try {
          const tRef = await tenantRefByStripeAccount(acct.id);
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
        } catch {
          console.warn("No tenant found in tenantStripeIndex for", acct.id);
        }
      }

      /* ========== 6) 保険: PI から初期費用確定 ========== */
      if (type === "payment_intent.succeeded") {
        const pi = event.data.object as Stripe.PaymentIntent;
        const kind = pi.metadata?.kind as string | undefined;
        const tenantId = pi.metadata?.tenantId as string | undefined;
        let uid = pi.metadata?.uid as string | undefined;

        if (kind === "initial_fee" && tenantId) {
          if (!uid) {
            const tRefIdx = await tenantRefByIndex(tenantId);
            uid = tRefIdx.parent!.id;
          }
          const tRef = tenantRefByUid(uid!, tenantId);
          await tRef.set(
            {
              billing: {
                initialFee: {
                  status: "paid",
                  amount: pi.amount_received ?? pi.amount ?? 0,
                  currency: (pi.currency ?? "jpy").toUpperCase(),
                  stripePaymentIntentId: pi.id,
                  paidAt: admin.firestore.FieldValue.serverTimestamp(),
                  updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                },
              },
            },
            { merge: true }
          );
        }
      }

      /* ========== トライアル終了予告（通知用に保存） ========== */
if (type === "customer.subscription.trial_will_end") {
  const sub = event.data.object as Stripe.Subscription;
  const tenantId = sub.metadata?.tenantId as string | undefined;
  let uid = sub.metadata?.uid as string | undefined;

  if (tenantId) {
    if (!uid) {
      const tRefIdx = await tenantRefByIndex(tenantId);
      uid = tRefIdx.parent!.id;
    }
    const trialEnd = sub.trial_end
      ? admin.firestore.Timestamp.fromMillis(sub.trial_end * 1000)
      : null;

    // 例: テナント直下に通知ドキュメントを積む（UIで表示/メール送信のトリガに）
    await db
      .collection(uid)
      .doc(tenantId)
      .collection("alerts")
      .add({
        type: "trial_will_end",
        stripeSubscriptionId: sub.id,
        trialEnd,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        read: false,
      });
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

/* ===================== Connect: Express（テナント直・参考） ===================== */
export const createConnectAccountForTenant = onCall(
  {
    region: "us-central1",
    memory: "256MiB",
    cors: [APP_ORIGIN, "http://localhost:65463"],
    secrets: ["STRIPE_SECRET_KEY"],
  },
  async (req) => {
    if (!req.auth) throw new HttpsError("unauthenticated", "auth required");
    const tenantId = req.data?.tenantId as string | undefined;
    if (!tenantId) throw new HttpsError("invalid-argument", "tenantId required");

    const stripe = stripeClient();

    // 旧: tenants/{tenantId}
    // Express 用は“グローバル”で持っている前提だったのでここは保持（必要なら uid 名空間化）
    const tRef = db.collection("tenants").doc(tenantId);
    const tSnap = await tRef.get();
    if (!tSnap.exists) throw new HttpsError("not-found", "tenant not found");
    const existing = tSnap.data()?.stripeAccountId as string | undefined;
    if (existing) return { stripeAccountId: existing, already: true };

    const acct = await stripe.accounts.create({
      type: "express",
      capabilities: { card_payments: { requested: true }, transfers: { requested: true } },
    });

    await tRef.set(
      {
        stripeAccountId: acct.id,
        connect: {
          charges_enabled: !!acct.charges_enabled,
          payouts_enabled: !!acct.payouts_enabled,
          details_submitted: !!acct.details_submitted,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
      },
      { merge: true }
    );

    return { stripeAccountId: acct.id };
  }
);

export const createAccountOnboardingLink = onCall(
  {
    region: "us-central1",
    memory: "256MiB",
    cors: [APP_ORIGIN, "http://localhost:65463"],
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

/* ===================== 招待（そのまま） ===================== */
export const inviteTenantAdmin = functions.https.onCall(async (data, context) => {
  const uid = context.auth?.uid;
  if (!uid) throw new functions.https.HttpsError("unauthenticated", "Sign in");

  const tenantId: string = data?.tenantId;
  const emailRaw: string = (data?.email || "").toString();
  const emailLower = emailRaw.trim().toLowerCase();
  if (!tenantId || !emailLower.includes("@")) {
    throw new functions.https.HttpsError("invalid-argument", "bad tenantId/email");
  }
  await assertTenantAdmin(tenantId, uid);

  const token = crypto.randomBytes(32).toString("hex");
  const tokenHash = sha256(token);
  const expiresAt = admin.firestore.Timestamp.fromDate(new Date(Date.now() + 1000 * 60 * 60 * 24 * 7));

  const inviteRef = db.collection(`tenants/${tenantId}/invites`).doc();
  await inviteRef.set({
    emailLower,
    tokenHash,
    status: "pending",
    invitedBy: {
      uid,
      email: context.auth?.token?.email || null,
    },
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    expiresAt,
  });

  const acceptUrl = `${APP_ORIGIN}/#/admin-invite?tenantId=${tenantId}&token=${token}`;

  await db.collection("mail").add({
    to: emailLower,
    message: {
      subject: "管理者招待のお知らせ",
      html: `
        <p>管理者として招待されました。</p>
        <p><a href="${acceptUrl}">こちらのリンク</a>を開いて承認してください（7日以内）。</p>
        <p>リンク: ${acceptUrl}</p>
      `,
    },
  });

  return { ok: true };
});

export const acceptTenantAdmin = functions.https.onCall(async (data, context) => {
  const uid = context.auth?.uid;
  const userEmail = (context.auth?.token?.email || "").toLowerCase();
  if (!uid || !userEmail) {
    throw new functions.https.HttpsError("unauthenticated", "Sign-in with email");
  }

  const tenantId: string = data?.tenantId;
  const token: string = data?.token;
  if (!tenantId || !token) {
    throw new functions.https.HttpsError("invalid-argument", "tenantId/token required");
  }
  const tokenHash = sha256(token);

  const invitesSnap = await db
    .collection(`tenants/${tenantId}/invites`)
    .where("tokenHash", "==", tokenHash)
    .limit(1)
    .get();
  if (invitesSnap.empty) {
    throw new functions.https.HttpsError("not-found", "Invite not found");
  }
  const inviteRef = invitesSnap.docs[0].ref;
  const inv = invitesSnap.docs[0].data();

  if (inv.status !== "pending") {
    throw new functions.https.HttpsError("failed-precondition", "Invite already used/revoked");
  }
  const now = admin.firestore.Timestamp.now();
  if (inv.expiresAt && now.toMillis() > inv.expiresAt.toMillis()) {
    throw new functions.https.HttpsError("deadline-exceeded", "Invite expired");
  }
  if (inv.emailLower !== userEmail) {
    throw new functions.https.HttpsError("permission-denied", "Email does not match invite");
  }

  const memRef = db.doc(`tenants/${tenantId}/members/${uid}`);
  const mem = await memRef.get();
  if (!mem.exists) {
    await memRef.set({
      role: "admin",
      email: userEmail,
      displayName: context.auth?.token?.name || null,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    await db.doc(`tenants/${tenantId}`).update({
      memberUids: admin.firestore.FieldValue.arrayUnion(uid),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  }

  await inviteRef.update({
    status: "accepted",
    acceptedBy: uid,
    acceptedAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  return { ok: true };
});

export const revokeInvite = functions.https.onCall(async (data, context) => {
  const uid = context.auth?.uid;
  if (!uid) throw new functions.https.HttpsError("unauthenticated", "Sign in");
  const tenantId: string = data?.tenantId;
  const inviteId: string = data?.inviteId;
  if (!tenantId || !inviteId) throw new functions.https.HttpsError("invalid-argument", "bad args");
  await assertTenantAdmin(tenantId, uid);
  await db.doc(`tenants/${tenantId}/invites/${inviteId}`).update({ status: "revoked" });
  return { ok: true };
});


/* ===================== サブスク Checkout ===================== */
export const createSubscriptionCheckout = functions
  .region("us-central1")
  .runWith({ secrets: ["STRIPE_SECRET_KEY", "FRONTEND_BASE_URL"] })
  .https.onCall(async (data, context) => {
    const uid = context.auth?.uid;
    if (!uid) throw new functions.https.HttpsError("unauthenticated", "Sign-in required");

    const { tenantId, plan, email, name } = (data || {}) as {
      tenantId: string;
      plan: string; // "A" | "B" | "C" を想定
      email?: string;
      name?: string;
    };
    if (!tenantId || !plan) {
      throw new functions.https.HttpsError("invalid-argument", "tenantId and plan are required.");
    }

    const STRIPE_KEY = process.env.STRIPE_SECRET_KEY!;
    const APP_BASE = process.env.FRONTEND_BASE_URL!;
    const stripe = new Stripe(STRIPE_KEY, { apiVersion: "2023-10-16" });

    const TRIAL_DAYS = 90;

    const planDoc = await getPlanFromDb(plan);
    const purchaserEmail = email || (context.auth?.token?.email as string | undefined);
    const customerId = await ensureCustomer(uid, tenantId, purchaserEmail, name);

    // 進行中購読があればポータルへ
    const subs = await stripe.subscriptions.list({ customer: customerId, status: "all", limit: 20 });
    const hasOngoing = subs.data.some((s) =>
      ["active", "trialing", "past_due", "unpaid"].includes(s.status)
    );
    if (hasOngoing) {
      const portal = await stripe.billingPortal.sessions.create({
        customer: customerId,
        return_url: `${APP_BASE}/#/settings?tenant=${encodeURIComponent(tenantId)}`,
      });
      return { alreadySubscribed: true, portalUrl: portal.url };
    }

    const successUrl = `${APP_BASE}/stripe-bridge.html#event=subscribed&tenant=${encodeURIComponent(
      tenantId
    )}&plan=${encodeURIComponent(plan)}`;
    const cancelUrl = `${APP_BASE}/stripe-bridge.html#event=subscription_canceled&tenant=${encodeURIComponent(
      tenantId
    )}`;

    const session = await stripe.checkout.sessions.create({
  mode: "subscription",
  customer: customerId,
  line_items: [{ price: planDoc.stripePriceId, quantity: 1 }],
  payment_method_collection: "always",
  allow_promotion_codes: true,

  // ★ 追加：セッションにもメタデータを入れる
  metadata: { tenantId, plan, uid },

  subscription_data: {
    trial_period_days: TRIAL_DAYS,
    // ここにも残す（後続の customer.subscription.* で参照できる）
    metadata: { tenantId, plan, uid },
  },

  success_url: successUrl,
  cancel_url: cancelUrl,
});

    await upsertTenantIndex(uid, tenantId);
    return { url: session.url };
  });

  export const changeSubscriptionPlan = functions
  .region("us-central1")
  .runWith({ secrets: ["STRIPE_SECRET_KEY"] })
  .https.onCall(async (data, context) => {
    const uid = context.auth?.uid;
    if (!uid) throw new functions.https.HttpsError("unauthenticated", "Sign-in required");

    const { subscriptionId, newPlan } = (data || {}) as {
      subscriptionId: string;
      newPlan: string; // "A" | "B" | "C"
    };
    if (!subscriptionId || !newPlan) {
      throw new functions.https.HttpsError("invalid-argument", "subscriptionId and newPlan are required.");
    }

    const STRIPE_KEY = process.env.STRIPE_SECRET_KEY!;
    const stripe = new Stripe(STRIPE_KEY, { apiVersion: "2023-10-16" });

    // 新プランの Price を解決
    const newPlanDoc = await getPlanFromDb(newPlan);

    // 現在の購読取得
    const sub = (await stripe.subscriptions.retrieve(subscriptionId)) as Stripe.Subscription;
    const item = sub.items.data[0];
    const trialEnd = sub.trial_end ?? undefined; // 既に trialing なら epoch 秒

    // トライアル中でも trial_end を維持し、差額課金を発生させない
    const updated = await stripe.subscriptions.update(subscriptionId, {
      items: [
        {
          id: item.id,
          price: newPlanDoc.stripePriceId,
          quantity: item.quantity ?? 1,
        },
      ],
      proration_behavior: "none",
      trial_end: trialEnd,        
      trial_from_plan: false,     
      
      metadata: { ...sub.metadata, plan: newPlan },
    });

    return { ok: true, subscription: updated.id };
  });



/* ===================== 請求書一覧 ===================== */
export const listInvoices = functions
  .region("us-central1")
  .runWith({ secrets: ["STRIPE_SECRET_KEY"] })
  .https.onCall(async (data, context) => {
    const uid = context.auth?.uid;
    if (!uid) throw new functions.https.HttpsError("unauthenticated", "Sign-in required");
    const { tenantId, limit } = (data || {}) as { tenantId: string; limit?: number };
    if (!tenantId) {
      throw new functions.https.HttpsError("invalid-argument", "tenantId is required.");
    }

    const STRIPE_KEY = process.env.STRIPE_SECRET_KEY!;
    const stripe = new Stripe(STRIPE_KEY, { apiVersion: "2023-10-16" });

    const tenantRef = tenantRefByUid(uid, tenantId);
    const t = (await tenantRef.get()).data() as { subscription?: TenantSubscription } | undefined;
    const customerId = t?.subscription?.stripeCustomerId;
    if (!customerId) return { invoices: [] };

    const resp = await stripe.invoices.list({
      customer: customerId,
      limit: Math.min(Math.max(limit ?? 12, 1), 50),
    });

    const invoices = resp.data.map((inv) => ({
      id: inv.id,
      number: inv.number,
      amount_due: inv.amount_due,
      amount_paid: inv.amount_paid,
      currency: inv.currency,
      status: inv.status,
      hosted_invoice_url: inv.hosted_invoice_url,
      invoice_pdf: inv.invoice_pdf,
      period_start: inv.lines?.data?.[0]?.period?.start ?? inv.created,
      period_end: inv.lines?.data?.[0]?.period?.end ?? inv.created,
      created: inv.created,
    }));

    return { invoices };
  });

/* ===================== Connect: Custom（uid/{tenantId}） ===================== */
export const upsertConnectedAccount = onCall(
  {
    region: "us-central1",
    memory: "256MiB",
    cors: [APP_ORIGIN, "http://localhost:5173", "http://localhost:65463"],
    secrets: ["STRIPE_SECRET_KEY", "FRONTEND_BASE_URL"],
  },
  async (req) => {
    if (!req.auth) throw new HttpsError("unauthenticated", "auth required");

    const uid = req.auth.uid;
    const tenantId = req.data?.tenantId as string | undefined;
    const form = (req.data?.account || {}) as any;

    if (!tenantId) throw new HttpsError("invalid-argument", "tenantId required");

    const tRef = tenantRefByUid(uid, tenantId);
    const tDoc = await tRef.get();
    if (!tDoc.exists) throw new HttpsError("not-found", "tenant not found");

    const members: string[] = (tDoc.data()?.members ?? []) as string[];
    if (!members.includes(uid)) {
      throw new HttpsError("permission-denied", "not a tenant member");
    }

    const stripe = stripeClient();
    let acctId: string | undefined = tDoc.data()?.stripeAccountId;
    const country = form.country || "JP";

    if (!acctId) {
      const created = await stripe.accounts.create({
        type: "custom",
        country,
        email: form.email,
        business_type: form.businessType || "individual",
        capabilities: { card_payments: { requested: true }, transfers: { requested: true } },
      });
      acctId = created.id;
      await tRef.set(
        {
          stripeAccountId: acctId,
          connect: {
            charges_enabled: created.charges_enabled,
            payouts_enabled: created.payouts_enabled,
          },
        },
        { merge: true }
      );
      await upsertTenantIndex(uid, tenantId, acctId); // ★ index
    }

    const upd: Stripe.AccountUpdateParams = {};
    if (form.businessType) upd.business_type = form.businessType;
    if (form.businessProfile) upd.business_profile = form.businessProfile;
    if (form.individual) upd.individual = form.individual;
    if (form.company) upd.company = form.company;
    if (form.bankAccountToken) upd.external_account = form.bankAccountToken;
    if (form.tosAccepted) {
      upd.tos_acceptance = {
        date: Math.floor(Date.now() / 1000),
        ip:
          (req.rawRequest.headers["x-forwarded-for"] as string)?.split(",")[0] ||
          req.rawRequest.ip,
        user_agent: req.rawRequest.get("user-agent") || undefined,
      };
    }

    const updated = await stripe.accounts.update(acctId!, upd);

    const due = updated.requirements?.currently_due ?? [];
    const pastDue = updated.requirements?.past_due ?? [];
    const needsHosted = due.length > 0 || pastDue.length > 0;

    let onboardingUrl: string | undefined;
    if (needsHosted) {
      const BASE = process.env.FRONTEND_BASE_URL!;
      const link = await stripe.accountLinks.create({
        account: acctId!,
        type: "account_onboarding",
        refresh_url: `${BASE}/#/connect-refresh?t=${tenantId}`,
        return_url: `${BASE}/#/connect-return?t=${tenantId}`,
      });
      onboardingUrl = link.url;
    }

    await tRef.set(
      {
        connect: {
          charges_enabled: updated.charges_enabled,
          payouts_enabled: updated.payouts_enabled,
          requirements: updated.requirements || null,
        },
      },
      { merge: true }
    );

    await upsertTenantIndex(uid, tenantId, acctId); // ★ index 保守

    return {
      accountId: acctId,
      chargesEnabled: updated.charges_enabled,
      payoutsEnabled: updated.payouts_enabled,
      due,
      onboardingUrl,
    };
  }
);

/* ===================== 初期費用 Checkout ===================== */
async function getOrCreateInitialFeePrice(
  stripe: Stripe,
  currency = "jpy",
  unitAmount = 3000,
  productName = "初期費用"
): Promise<string> {
  const ENV_PRICE = process.env.INITIAL_FEE_PRICE_ID;
  if (ENV_PRICE) return ENV_PRICE;

  const products = await stripe.products.search({
    query: `name:'${productName}' AND metadata['kind']:'initial_fee'`,
    limit: 1,
  });
  let productId = products.data[0]?.id;
  if (!productId) {
    const p = await stripe.products.create({
      name: productName,
      metadata: { kind: "initial_fee" },
    });
    productId = p.id;
  }

  const prices = await stripe.prices.search({
    query:
      `product:'${productId}' AND ` +
      `currency:'${currency}' AND ` +
      `active:'true' AND ` +
      `type:'one_time' AND ` +
      `unit_amount:'${unitAmount}'`,
    limit: 1,
  });
  if (prices.data[0]) return prices.data[0].id;

  const price = await stripe.prices.create({
    product: productId,
    currency,
    unit_amount: unitAmount,
    metadata: { kind: "initial_fee" },
  });
  return price.id;
}

export const createInitialFeeCheckout = functions
  .region("us-central1")
  .runWith({
    secrets: ["STRIPE_SECRET_KEY", "FRONTEND_BASE_URL", "INITIAL_FEE_PRICE_ID"],
  })
  .https.onCall(async (data, context) => {
    const uid = context.auth?.uid;
    if (!uid) {
      throw new functions.https.HttpsError("unauthenticated", "Sign-in required.");
    }

    const { tenantId, email, name } = (data || {}) as {
      tenantId?: string;
      email?: string;
      name?: string;
    };
    if (!tenantId) {
      throw new functions.https.HttpsError("invalid-argument", "tenantId is required.");
    }

    const STRIPE_KEY = process.env.STRIPE_SECRET_KEY!;
    const APP_BASE = process.env.FRONTEND_BASE_URL!;
    const stripe = new Stripe(STRIPE_KEY, { apiVersion: "2023-10-16" });

    const tRef = tenantRefByUid(uid, tenantId);
    const tSnap = await tRef.get();
    if (tSnap.exists && tSnap.data()?.billing?.initialFee?.status === "paid") {
      return { alreadyPaid: true };
    }

    const purchaserEmail = email || (context.auth?.token?.email as string | undefined);
    const customerId = await ensureCustomer(uid, tenantId, purchaserEmail, name);
    const priceId = await getOrCreateInitialFeePrice(stripe);

    const successUrl = `${APP_BASE}/stripe-bridge.html#event=initial_fee_paid&tenant=${encodeURIComponent(
      tenantId
    )}`;
    const cancelUrl = `${APP_BASE}/stripe-bridge.html#event=initial_fee_canceled&tenant=${encodeURIComponent(
      tenantId
    )}`;

    const session = await stripe.checkout.sessions.create({
      mode: "payment",
      customer: customerId,
      line_items: [{ price: priceId, quantity: 1 }],
      client_reference_id: tenantId,
      payment_intent_data: { metadata: { tenantId, kind: "initial_fee", uid } },
      success_url: successUrl,
      cancel_url: cancelUrl,
    });

    await tRef.set(
      {
        billing: {
          initialFee: {
            status: "checkout_open",
            lastSessionId: session.id,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
        },
      },
      { merge: true }
    );

    await upsertTenantIndex(uid, tenantId);
    return { url: session.url };
  });
