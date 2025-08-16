import * as functions from "firebase-functions";
import * as admin from "firebase-admin";
import Stripe from "stripe";
// ローカル開発で .env を使う場合だけ（本番は Secrets）
import * as dotenv from "dotenv";
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
export const stripeWebhook =
  functions.region("us-central1")
  .runWith({ secrets: ["STRIPE_SECRET_KEY", "STRIPE_WEBHOOK_SECRET", "FRONTEND_BASE_URL"], memory: "256MB" })
  .https.onRequest(async (req, res) => {
    const sig = req.headers["stripe-signature"] as string | undefined;
    if (!sig) {
      res.status(400).send("No signature");
      return;
    }

    const stripe = stripeClient();
    let event: Stripe.Event;
    try {
      event = stripe.webhooks.constructEvent(
        (req as any).rawBody, // Firebase Functions は rawBody を提供
        sig,
        requireEnv("STRIPE_WEBHOOK_SECRET")
      );
    } catch (err: any) {
      console.error("Webhook signature verification failed.", err?.message);
      res.status(400).send(`Webhook Error: ${err?.message}`);
      return;
    }

    const type = event.type;
    const docRef = db.collection("webhookEvents").doc(event.id);
    await docRef.set({ type, receivedAt: admin.firestore.FieldValue.serverTimestamp(), handled: false });

    try {
      if (type === "checkout.session.completed") {
        const session = event.data.object as Stripe.Checkout.Session;
        const sid = session.id;
        const tenantId = session.metadata?.tenantId!;
        const employeeId = session.metadata?.employeeId as string | undefined;
        const payIntentId = session.payment_intent as string;

        if (employeeId) {
          // ---- チップのケース ----
          await db.collection("tipSessions").doc(sid).set({
            status: "paid",
            paidAt: admin.firestore.FieldValue.serverTimestamp(),
          }, { merge: true });

          await db.collection("tips").doc(payIntentId || sid).set({
            tenantId,
            employeeId,
            sessionId: sid,
            amount: session.amount_total ?? 0,
            currency: (session.currency ?? "jpy").toUpperCase(),
            status: "succeeded",
            stripePaymentIntentId: payIntentId ?? "",
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          }, { merge: true });

        } else {
          // ---- 通常の店舗決済（paymentSessions）のケース ----
          await db.collection("paymentSessions").doc(sid).set({
            status: "paid",
            paidAt: admin.firestore.FieldValue.serverTimestamp(),
          }, { merge: true });

          const paymentId = payIntentId || sid;
          await db.collection("payments").doc(paymentId).set({
            tenantId,
            sessionId: sid,
            amount: session.amount_total ?? 0,
            currency: (session.currency ?? "jpy").toUpperCase(),
            status: "succeeded",
            stripePaymentIntentId: payIntentId ?? "",
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          }, { merge: true });
        }
      }

      // 返金/失敗などの追加ハンドリングは必要に応じて
      if (type === "charge.refunded" || type === "payment_intent.payment_failed") {
        // TODO: payments / sessions を更新
      }

      await docRef.set({ handled: true }, { merge: true });
      res.sendStatus(200);
    } catch (e) {
      console.error(e);
      res.sendStatus(500);
    }
  });

/** 公開ページ（未ログイン）からのチップ用 */
export const createTipSessionPublic =
  functions.region("us-central1")
  .runWith({ secrets: ["STRIPE_SECRET_KEY", "FRONTEND_BASE_URL"], memory: "256MB" })
  .https.onCall(async (data, _ctx) => {
    const { tenantId, employeeId, amount, memo = "Tip" } = data as {
      tenantId?: string; employeeId?: string; amount?: number; memo?: string;
    };

    if (!tenantId || !employeeId) {
      throw new functions.https.HttpsError("invalid-argument", "tenantId/employeeId required");
    }
    if (!Number.isInteger(amount) || (amount ?? 0) <= 0 || (amount as number) > 1_000_000) {
      throw new functions.https.HttpsError("invalid-argument", "invalid amount");
    }

    // テナント/従業員の存在確認 & 稼働状態
    const tDoc = await db.collection("tenants").doc(tenantId).get();
    if (!tDoc.exists || tDoc.data()!.status !== "active") {
      throw new functions.https.HttpsError("failed-precondition", "Tenant suspended or not found");
    }
    const eDoc = await db.collection("tenants").doc(tenantId)
      .collection("employees").doc(employeeId).get();
    if (!eDoc.exists) {
      throw new functions.https.HttpsError("not-found", "Employee not found");
    }

    const FRONTEND_BASE_URL = requireEnv("FRONTEND_BASE_URL");
    const stripe = stripeClient();
    const empName = (eDoc.data()?.name as string) ?? "Staff";

    try {
      const session = await stripe.checkout.sessions.create({
        mode: "payment",
        payment_method_types: ["card", "link"],
        line_items: [{
          price_data: {
            currency: "JPY",
            product_data: { name: `Tip to ${empName}` },
            unit_amount: amount!,
          },
          quantity: 1,
        }],
        // Netlify でも確実に動くハッシュ方式
        success_url: `${FRONTEND_BASE_URL}/#/p?t=${tenantId}&thanks=true`,
        cancel_url: `${FRONTEND_BASE_URL}/#/p?t=${tenantId}&canceled=true`,
        metadata: { tenantId, employeeId, memo },
      });

      await db.collection("tipSessions").doc(session.id).set({
        tenantId,
        employeeId,
        amount,
        status: "pending",
        stripeCheckoutUrl: session.url,
        stripeSessionId: session.id,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      return { checkoutUrl: session.url, sessionId: session.id };
    } catch (err: any) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        err?.message || "Stripe error",
        { source: "stripe", code: err?.type || "stripe_error" }
      );
    }
  });

// 他ファイルの関数もまとめてエクスポート
export * from "./setUserClaims";
