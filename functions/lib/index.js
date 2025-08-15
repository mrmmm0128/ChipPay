"use strict";
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.stripeWebhook = exports.createCheckoutSession = void 0;
const functions = __importStar(require("firebase-functions"));
const admin = __importStar(require("firebase-admin"));
const stripe_1 = __importDefault(require("stripe"));
const dotenv = __importStar(require("dotenv"));
dotenv.config();
admin.initializeApp();
const db = admin.firestore();
const stripe = new stripe_1.default(process.env.STRIPE_SECRET_KEY, { apiVersion: "2023-10-16" });
/**
 * 認可: tenantIdとroleをトークンから取得
 */
function requireAuthAndTenant(ctx) {
    if (!ctx.auth)
        throw new functions.https.HttpsError("unauthenticated", "Sign in required");
    const tenantId = ctx.auth.token.tenantId;
    const role = ctx.auth.token.role;
    if (!tenantId)
        throw new functions.https.HttpsError("permission-denied", "No tenant");
    if (!role)
        throw new functions.https.HttpsError("permission-denied", "No role");
    return { tenantId, role };
}
/**
 * 店舗が金額入力 → Checkout セッション発行
 */
exports.createCheckoutSession = functions.https.onCall(async (data, ctx) => {
    const { tenantId } = requireAuthAndTenant(ctx);
    const { amount, currency = "JPY", memo = "" } = data;
    if (!Number.isInteger(amount) || amount <= 0) {
        throw new functions.https.HttpsError("invalid-argument", "amount must be positive integer");
    }
    // テナントの稼働状態を確認
    const tDoc = await db.collection("tenants").doc(tenantId).get();
    if (!tDoc.exists || tDoc.data().status !== "active") {
        throw new functions.https.HttpsError("failed-precondition", "Tenant suspended or not found");
    }
    // Stripe Checkout Session 作成（Hosted型）
    const session = await stripe.checkout.sessions.create({
        mode: "payment",
        payment_method_types: ["card", "link"], // Apple/Google Payはcardに内包（ブラウザ対応時）
        line_items: [
            { price_data: { currency, product_data: { name: `Order - ${tDoc.data().name}` }, unit_amount: amount }, quantity: 1 }
        ],
        success_url: `${process.env.FRONTEND_BASE_URL}/succeeded?sid={CHECKOUT_SESSION_ID}`,
        cancel_url: `${process.env.FRONTEND_BASE_URL}/canceled`,
        metadata: { tenantId, memo },
    });
    // Firestore にセッション保存
    const ref = db.collection("paymentSessions").doc(session.id);
    await ref.set({
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
});
/**
 * Stripe Webhook
 * 重要：functions:configではなく環境変数（.env）/ デプロイ時の設定で管理
 */
exports.stripeWebhook = functions.https.onRequest(async (req, res) => {
    const sig = req.headers["stripe-signature"];
    if (!sig) {
        res.status(400).send("No signature");
        return;
    }
    let event;
    try {
        event = stripe.webhooks.constructEvent(req.rawBody, sig, process.env.STRIPE_WEBHOOK_SECRET);
    }
    catch (err) {
        console.error("Webhook signature verification failed.", err.message);
        res.status(400).send(`Webhook Error: ${err.message}`);
        return;
    }
    const type = event.type;
    const docRef = db.collection("webhookEvents").doc(event.id);
    await docRef.set({ type, receivedAt: admin.firestore.FieldValue.serverTimestamp(), handled: false });
    try {
        if (type === "checkout.session.completed") {
            const session = event.data.object;
            const sid = session.id;
            const tenantId = session.metadata?.tenantId;
            const payIntentId = session.payment_intent;
            // セッション更新
            await db.collection("paymentSessions").doc(sid).set({
                status: "paid",
                paidAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });
            // payments へ記録
            const paymentId = payIntentId || sid;
            await db.collection("payments").doc(paymentId).set({
                tenantId,
                sessionId: sid,
                amount: session.amount_total ?? 0,
                currency: session.currency?.toUpperCase() ?? "JPY",
                status: "succeeded",
                stripePaymentIntentId: payIntentId ?? "",
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });
        }
        if (type === "charge.refunded" || type === "payment_intent.payment_failed") {
            // 必要に応じて payments / sessions を更新
        }
        await docRef.set({ handled: true }, { merge: true });
        res.sendStatus(200);
    }
    catch (e) {
        console.error(e);
        res.sendStatus(500);
    }
});
