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
exports.createInitialFeeCheckout = exports.upsertConnectedAccount = exports.listInvoices = exports.openCustomerPortal = exports.createSubscriptionCheckout = exports.revokeInvite = exports.acceptTenantAdmin = exports.inviteTenantAdmin = exports.createAccountOnboardingLink = exports.createConnectAccountForTenant = exports.stripeWebhook = exports.onTipSucceededSendMailV2 = exports.createStoreTipSessionPublic = exports.createTipSessionPublic = exports.RESEND_API_KEY = void 0;
/* eslint-disable @typescript-eslint/no-explicit-any */
const functions = __importStar(require("firebase-functions"));
const https_1 = require("firebase-functions/v2/https");
const firestore_1 = require("firebase-functions/v2/firestore");
const params_1 = require("firebase-functions/params");
const admin = __importStar(require("firebase-admin"));
const stripe_1 = __importDefault(require("stripe"));
const crypto = __importStar(require("crypto"));
if (!admin.apps.length)
    admin.initializeApp();
const db = admin.firestore();
/* ===================== Secrets / Const ===================== */
exports.RESEND_API_KEY = (0, params_1.defineSecret)("RESEND_API_KEY");
const APP_ORIGIN = "https://venerable-mermaid-fcf8c8.netlify.app";
/* ===================== Utils ===================== */
function requireEnv(name) {
    const v = process.env[name];
    if (!v) {
        throw new functions.https.HttpsError("failed-precondition", `Server misconfigured: missing ${name}`);
    }
    return v;
}
function calcApplicationFee(amount, feeCfg) {
    const p = Math.max(0, Math.min(100, Math.floor(feeCfg?.percent ?? 0)));
    const f = Math.max(0, Math.floor(feeCfg?.fixed ?? 0));
    const percentPart = Math.floor((amount * p) / 100);
    return percentPart + f;
}
let _stripe = null;
function stripeClient() {
    if (_stripe)
        return _stripe;
    _stripe = new stripe_1.default(requireEnv("STRIPE_SECRET_KEY"), {
        apiVersion: "2023-10-16",
    });
    return _stripe;
}
function sha256(s) {
    return crypto.createHash("sha256").update(s).digest("hex");
}
function escapeHtml(s) {
    return s.replace(/[&<>'"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" }[c]));
}
function tenantRefByUid(uid, tenantId) {
    return db.collection(uid).doc(tenantId);
}
async function tenantRefByIndex(tenantId) {
    const idx = await db.collection("tenantIndex").doc(tenantId).get();
    if (!idx.exists)
        throw new Error(`tenantIndex not found for ${tenantId}`);
    const { uid } = idx.data();
    return tenantRefByUid(uid, tenantId);
}
async function tenantRefByStripeAccount(acctId) {
    const qs = await db
        .collection("tenantStripeIndex")
        .where("stripeAccountId", "==", acctId)
        .limit(1)
        .get();
    if (qs.empty)
        throw new Error("tenantStripeIndex not found");
    const { uid, tenantId } = qs.docs[0].data();
    return tenantRefByUid(uid, tenantId);
}
async function upsertTenantIndex(uid, tenantId, stripeAccountId) {
    await db.collection("tenantIndex").doc(tenantId).set({
        uid,
        tenantId,
        ...(stripeAccountId ? { stripeAccountId } : {}),
    }, { merge: true });
    if (stripeAccountId) {
        await db
            .collection("tenantStripeIndex")
            .doc(tenantId)
            .set({ uid, tenantId, stripeAccountId }, { merge: true });
    }
}
/* ===================== Firestore ルール系 ===================== */
async function assertTenantAdmin(tenantId, uid) {
    const mem = await db.doc(`tenants/${tenantId}/members/${uid}`).get();
    if (mem.exists && mem.data()?.role === "admin")
        return;
    const t = await db.doc(`tenants/${tenantId}`).get();
    const arr = (t.data()?.memberUids || []);
    if (arr.includes(uid))
        return;
    throw new functions.https.HttpsError("permission-denied", "Not tenant admin");
}
async function pickEffectiveRule(tenantId, at) {
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
    const sd = cur.data()?.storeDeduction ?? {};
    return {
        percent: Number(sd.percent ?? 0),
        fixed: Number(sd.fixed ?? 0),
        effectiveFrom: null,
    };
}
function splitMinor(amountMinor, percent, fixedMinor) {
    const percentPart = Math.floor(amountMinor * (Math.max(0, percent) / 100));
    const store = Math.min(Math.max(0, amountMinor), Math.max(0, percentPart + Math.max(0, fixedMinor)));
    const staff = amountMinor - store;
    return { storeAmount: store, staffAmount: staff };
}
async function getPlanFromDb(planId) {
    let snap = await db.collection("billingPlans").doc(planId).get();
    if (snap.exists)
        return snap.data();
    snap = await db.collection("billing").doc("plans").get();
    if (snap.exists) {
        const data = snap.data() || {};
        const candidate = (data.plans && data.plans[planId]) || data[planId];
        if (candidate?.stripePriceId)
            return candidate;
    }
    snap = await db.collection("billing").doc("plans").collection("plans").doc(planId).get();
    if (snap.exists)
        return snap.data();
    throw new functions.https.HttpsError("not-found", `Plan "${planId}" not found in billingPlans/{id}, billing/plans(plans map), or billing/plans/plans/{id}.`);
}
async function ensureCustomer(uid, tenantId, email, name) {
    const stripe = new stripe_1.default(requireEnv("STRIPE_SECRET_KEY"), {
        apiVersion: "2023-10-16",
    });
    const tenantRef = tenantRefByUid(uid, tenantId);
    const tSnap = await tenantRef.get();
    const tData = (tSnap.data() || {});
    const sub = tData.subscription || {};
    if (sub.stripeCustomerId)
        return sub.stripeCustomerId;
    const customer = await stripe.customers.create({
        email,
        name,
        metadata: { tenantId, uid },
    });
    await tenantRef.set({ subscription: { ...(sub || {}), stripeCustomerId: customer.id } }, { merge: true });
    // index の担保
    await upsertTenantIndex(uid, tenantId);
    return customer.id;
}
/* ============================================================
 *  公開ページ: チップ（スタッフ宛）
 *  ※ uid 不明 → tenantIndex から逆引き
 * ==========================================================*/
exports.createTipSessionPublic = functions
    .region("us-central1")
    .runWith({
    secrets: ["STRIPE_SECRET_KEY", "FRONTEND_BASE_URL"],
    memory: "256MB",
})
    .https.onCall(async (data) => {
    const { tenantId, employeeId, amount, memo = "Tip" } = data;
    if (!tenantId || !employeeId) {
        throw new functions.https.HttpsError("invalid-argument", "tenantId/employeeId required");
    }
    if (!Number.isInteger(amount) || (amount ?? 0) <= 0 || amount > 1000000) {
        throw new functions.https.HttpsError("invalid-argument", "invalid amount");
    }
    // uid を逆引きして uid/{tenantId} を参照
    const tRef = await tenantRefByIndex(tenantId);
    const tDoc = await tRef.get();
    if (!tDoc.exists || tDoc.data().status !== "active") {
        throw new functions.https.HttpsError("failed-precondition", "Tenant suspended or not found");
    }
    const acctId = tDoc.data()?.stripeAccountId;
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
    const employeeName = eDoc.data()?.name ?? "Staff";
    const sub = (tDoc.data()?.subscription ?? {});
    const plan = (sub.plan ?? "A").toUpperCase();
    const percent = typeof sub.feePercent === "number"
        ? sub.feePercent
        : plan === "B" ? 15 : plan === "C" ? 10 : 20;
    const appFee = calcApplicationFee(amount, { percent, fixed: 0 });
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
                    unit_amount: amount,
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
exports.createStoreTipSessionPublic = functions
    .region("us-central1")
    .runWith({
    secrets: ["STRIPE_SECRET_KEY", "FRONTEND_BASE_URL"],
    memory: "256MB",
})
    .https.onCall(async (data) => {
    const { tenantId, amount, memo = "Tip to store" } = data;
    if (!tenantId) {
        throw new functions.https.HttpsError("invalid-argument", "tenantId required");
    }
    if (!Number.isInteger(amount) || (amount ?? 0) <= 0 || amount > 1000000) {
        throw new functions.https.HttpsError("invalid-argument", "invalid amount");
    }
    const tRef = await tenantRefByIndex(tenantId);
    const tDoc = await tRef.get();
    if (!tDoc.exists || tDoc.data().status !== "active") {
        throw new functions.https.HttpsError("failed-precondition", "Tenant suspended or not found");
    }
    const acctId = tDoc.data()?.stripeAccountId;
    if (!acctId) {
        throw new functions.https.HttpsError("failed-precondition", "Store not connected to Stripe");
    }
    const chargesEnabled = !!tDoc.data()?.connect?.charges_enabled;
    if (!chargesEnabled) {
        throw new functions.https.HttpsError("failed-precondition", "Store Stripe account is not ready (charges_disabled)");
    }
    const sub = (tDoc.data()?.subscription ?? {});
    const plan = (sub.plan ?? "A").toUpperCase();
    const percent = typeof sub.feePercent === "number"
        ? sub.feePercent
        : plan === "B" ? 15 : plan === "C" ? 10 : 20;
    const appFee = calcApplicationFee(amount, { percent, fixed: 0 });
    const storeName = tDoc.data()?.name ?? tenantId;
    // uid を取得（親コレクション名 = uid）
    const uid = tRef.parent.id;
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
    const unitAmount = amount;
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
        .set({
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
    }, { merge: true });
    return { checkoutUrl: session.url, sessionId: session.id, tipDocId: tipRef.id };
});
/* ===================== チップ成功メール（既存: uid/{tenantId}/tips） ===================== */
exports.onTipSucceededSendMailV2 = (0, firestore_1.onDocumentWritten)({
    region: "us-central1",
    document: "{uid}/{tenantId}/tips/{tipId}",
    secrets: [exports.RESEND_API_KEY],
    memory: "256MiB",
    maxInstances: 10,
}, async (event) => {
    const before = event.data?.before?.data();
    const after = event.data?.after?.data();
    if (!after)
        return;
    const beforeStatus = before?.status;
    const afterStatus = after?.status;
    if (afterStatus !== "succeeded" || beforeStatus === "succeeded")
        return;
    await sendTipNotification(event.params.tenantId, event.params.tipId, exports.RESEND_API_KEY.value(), event.params.uid);
});
async function sendTipNotification(tenantId, tipId, resendApiKey, uid) {
    const tipRef = db.collection(uid).doc(tenantId).collection("tips").doc(tipId);
    const tipSnap = await tipRef.get();
    if (!tipSnap.exists)
        return;
    const tip = tipSnap.data();
    const amount = tip.amount ?? 0;
    const currency = tip.currency?.toUpperCase() ?? "JPY";
    const recipient = tip.recipient ?? {};
    const isEmployee = recipient.type === "employee" || !!tip.employeeId;
    const to = [];
    if (isEmployee) {
        const empId = tip.employeeId ?? recipient.employeeId;
        if (empId) {
            const empSnap = await db
                .collection(uid)
                .doc(tenantId)
                .collection("employees")
                .doc(empId)
                .get();
            const empEmail = empSnap.get("email");
            if (empEmail)
                to.push(empEmail);
        }
    }
    else {
        const tenSnap = await db.collection(uid).doc(tenantId).get();
        const notify = tenSnap.get("notificationEmails");
        if (notify?.length)
            to.push(...notify);
    }
    if (to.length === 0) {
        const fallback = tip.employeeEmail ||
            recipient.employeeEmail ||
            tip.storeEmail;
        if (fallback)
            to.push(fallback);
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
    const memo = tip.memo || "";
    const createdAt = tip.createdAt?.toDate?.() ?? new Date();
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
    const { Resend } = await Promise.resolve().then(() => __importStar(require("resend")));
    const resend = new Resend(resendApiKey);
    await resend.emails.send({
        from: "YourPay 通知 <sendtip_app@appfromkomeda.jp>",
        to,
        subject,
        text,
        html,
    });
    await tipRef.set({ notification: { emailedAt: admin.firestore.FieldValue.serverTimestamp(), to } }, { merge: true });
}
/* ===================== Stripe Webhook ===================== */
exports.stripeWebhook = functions
    .region("us-central1")
    .runWith({
    secrets: [
        "STRIPE_SECRET_KEY",
        "STRIPE_WEBHOOK_SECRET",
        "STRIPE_CONNECT_WEBHOOK_SECRET",
        "FRONTEND_BASE_URL",
    ],
    memory: "256MB",
})
    .https.onRequest(async (req, res) => {
    const sig = req.headers["stripe-signature"];
    if (!sig) {
        res.status(400).send("No signature");
        return;
    }
    const stripe = stripeClient();
    const secrets = [
        process.env.STRIPE_WEBHOOK_SECRET,
        process.env.STRIPE_CONNECT_WEBHOOK_SECRET,
    ].filter(Boolean);
    let event = null;
    for (const secret of secrets) {
        try {
            event = stripe.webhooks.constructEvent(req.rawBody, sig, secret);
            break;
        }
        catch {
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
            const session = event.data.object;
            // A. サブスク
            if (session.mode === "subscription") {
                const tenantId = session.metadata?.tenantId;
                const uidMeta = session.metadata?.uid;
                const plan = session.metadata?.plan;
                const subscriptionId = session.subscription;
                const customerId = session.customer ?? undefined;
                if (!tenantId || !subscriptionId) {
                    console.error("subscription checkout completed but missing tenantId or subscriptionId");
                }
                else {
                    const sub = await stripe.subscriptions.retrieve(subscriptionId);
                    let feePercent;
                    if (plan) {
                        const planSnap = await db.doc(`billing/plans/${plan}`).get();
                        feePercent = planSnap.exists ? planSnap.data()?.feePercent : undefined;
                    }
                    // uid の確定（meta 優先 → index）
                    let uid = uidMeta;
                    if (!uid) {
                        const tRefIdx = await tenantRefByIndex(tenantId);
                        uid = tRefIdx.parent.id;
                    }
                    const tRef = tenantRefByUid(uid, tenantId);
                    await tRef.set({
                        subscription: {
                            plan,
                            status: sub.status,
                            stripeCustomerId: customerId,
                            stripeSubscriptionId: sub.id,
                            currentPeriodEnd: admin.firestore.Timestamp.fromMillis(sub.current_period_end * 1000),
                            ...(typeof feePercent === "number" ? { feePercent } : {}),
                        },
                    }, { merge: true });
                }
                await docRef.set({ handled: true }, { merge: true });
                res.sendStatus(200);
                return;
            }
            // B. 初期費用（mode=payment & kind=initial_fee）
            if (session.mode === "payment") {
                let tenantId = session.metadata?.tenantId ??
                    session.client_reference_id;
                let uidMeta = session.metadata?.uid;
                let isInitialFee = false;
                const paymentIntentId = session.payment_intent;
                if (paymentIntentId) {
                    const pi = await stripe.paymentIntents.retrieve(paymentIntentId);
                    const kind = pi.metadata?.kind ??
                        session.metadata?.kind;
                    if (!tenantId)
                        tenantId = pi.metadata?.tenantId;
                    if (!uidMeta)
                        uidMeta = pi.metadata?.uid;
                    isInitialFee = kind === "initial_fee";
                }
                if (isInitialFee && tenantId) {
                    let uid = uidMeta;
                    if (!uid) {
                        const tRefIdx = await tenantRefByIndex(tenantId);
                        uid = tRefIdx.parent.id;
                    }
                    const tRef = tenantRefByUid(uid, tenantId);
                    await tRef.set({
                        initialFee: {
                            status: "paid",
                            amount: session.amount_total ?? 0,
                            currency: (session.currency ?? "jpy").toUpperCase(),
                            stripePaymentIntentId: paymentIntentId ?? null,
                            stripeCheckoutSessionId: session.id,
                            paidAt: admin.firestore.FieldValue.serverTimestamp(),
                            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                        },
                    }, { merge: true });
                    await docRef.set({ handled: true }, { merge: true });
                    res.sendStatus(200);
                    return;
                }
            }
            // C. チップ（mode=payment の通常ルート）
            const sid = session.id;
            const tenantIdMeta = session.metadata?.tenantId;
            const employeeId = session.metadata?.employeeId;
            let employeeName = session.metadata?.employeeName;
            const payIntentId = session.payment_intent;
            let uid = session.metadata?.uid;
            const stripeCreatedSec = session.created ?? event.created;
            const createdAtTs = admin.firestore.Timestamp.fromMillis((stripeCreatedSec ?? Math.floor(Date.now() / 1000)) * 1000);
            if (!tenantIdMeta) {
                console.error("checkout.session.completed: missing tenantId in metadata");
            }
            else {
                if (!uid) {
                    const tRefIdx = await tenantRefByIndex(tenantIdMeta);
                    uid = tRefIdx.parent.id;
                }
                const tRef = tenantRefByUid(uid, tenantIdMeta);
                await tRef
                    .collection("tipSessions")
                    .doc(sid)
                    .set({
                    status: "paid",
                    paidAt: admin.firestore.FieldValue.serverTimestamp(),
                    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                }, { merge: true });
                const tipDocId = session.metadata?.tipDocId || payIntentId || sid;
                let storeName = session.metadata?.storeName;
                if (!storeName) {
                    const tSnap = await tRef.get();
                    storeName = (tSnap.exists && tSnap.data()?.name) || "Store";
                }
                if (employeeId && !employeeName) {
                    const eSnap = await tRef.collection("employees").doc(employeeId).get();
                    employeeName = (eSnap.exists && eSnap.data()?.name) || "Staff";
                }
                const recipient = employeeId
                    ? { type: "employee", employeeId, employeeName: employeeName || "Staff" }
                    : { type: "store", storeName: storeName };
                const tipRef = tRef.collection("tips").doc(tipDocId);
                const tipSnap = await tipRef.get();
                const existingCreatedAt = tipSnap.exists ? tipSnap.data()?.createdAt : null;
                await tipRef.set({
                    tenantId: tenantIdMeta,
                    sessionId: sid,
                    amount: session.amount_total ?? 0,
                    currency: (session.currency ?? "jpy").toUpperCase(),
                    status: "succeeded",
                    stripePaymentIntentId: payIntentId ?? "",
                    recipient,
                    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                    createdAt: existingCreatedAt ?? createdAtTs,
                }, { merge: true });
                const tipAfter = await tipRef.get();
                const alreadySplit = !!tipAfter.data()?.split?.storeAmount;
                if (!alreadySplit) {
                    const eff = await pickEffectiveRule(tenantIdMeta, createdAtTs.toDate());
                    const totalMinor = (session.amount_total ?? 0);
                    const { storeAmount, staffAmount } = splitMinor(totalMinor, eff.percent, eff.fixed);
                    await tipRef.set({
                        split: {
                            percentApplied: eff.percent,
                            fixedApplied: eff.fixed,
                            effectiveFrom: eff.effectiveFrom ?? null,
                            computedAt: admin.firestore.FieldValue.serverTimestamp(),
                            storeAmount,
                            staffAmount,
                        },
                    }, { merge: true });
                }
                try {
                    if (payIntentId) {
                        const pi = await stripe.paymentIntents.retrieve(payIntentId, {
                            expand: ["latest_charge.balance_transaction"],
                        });
                        const latestCharge = pi.latest_charge || null;
                        const bt = latestCharge?.balance_transaction;
                        const stripeFee = bt?.fee ?? 0;
                        const stripeFeeCurrency = bt?.currency?.toUpperCase() ??
                            (session.currency ?? "jpy").toUpperCase();
                        const appFeeAmount = latestCharge?.application_fee_amount ?? 0;
                        const splitNow = (await tipRef.get()).data()?.split ?? {};
                        const storeCut = splitNow.storeAmount ?? 0;
                        const gross = (session.amount_total ?? 0);
                        const isStaff = !!employeeId;
                        const toStore = isStaff
                            ? storeCut
                            : Math.max(0, gross - appFeeAmount - stripeFee);
                        const toStaff = isStaff
                            ? Math.max(0, gross - appFeeAmount - stripeFee - storeCut)
                            : 0;
                        await tipRef.set({
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
                        }, { merge: true });
                    }
                }
                catch (err) {
                    console.error("Failed to enrich tip with stripe fee:", err);
                }
            }
        }
        /* ========== 2) Checkout その他 ========== */
        if (type === "checkout.session.expired" || type === "checkout.session.async_payment_failed") {
            const session = event.data.object;
            const tenantId = session.metadata?.tenantId;
            if (tenantId) {
                let uid = session.metadata?.uid;
                if (!uid) {
                    const tRefIdx = await tenantRefByIndex(tenantId);
                    uid = tRefIdx.parent.id;
                }
                await tenantRefByUid(uid, tenantId)
                    .collection("tipSessions")
                    .doc(session.id)
                    .set({
                    status: type.endsWith("failed") ? "failed" : "expired",
                    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                }, { merge: true });
            }
        }
        /* ========== 3) 購読の作成/更新/削除 ========== */
        if (type === "customer.subscription.created" || type === "customer.subscription.updated") {
            const sub = event.data.object;
            const tenantId = sub.metadata?.tenantId;
            const plan = sub.metadata?.plan;
            let uid = sub.metadata?.uid;
            if (tenantId) {
                if (!uid) {
                    const tRefIdx = await tenantRefByIndex(tenantId);
                    uid = tRefIdx.parent.id;
                }
                let feePercent;
                if (plan) {
                    const planSnap = await db.doc(`billing/plans/${plan}`).get();
                    feePercent = planSnap.exists ? planSnap.data()?.feePercent : undefined;
                }
                await tenantRefByUid(uid, tenantId).set({
                    subscription: {
                        plan,
                        status: sub.status,
                        stripeCustomerId: sub.customer ?? undefined,
                        stripeSubscriptionId: sub.id,
                        currentPeriodEnd: admin.firestore.Timestamp.fromMillis(sub.current_period_end * 1000),
                        ...(typeof feePercent === "number" ? { feePercent } : {}),
                    },
                }, { merge: true });
            }
        }
        if (type === "customer.subscription.deleted") {
            const sub = event.data.object;
            const tenantId = sub.metadata?.tenantId;
            let uid = sub.metadata?.uid;
            if (tenantId) {
                if (!uid) {
                    const tRefIdx = await tenantRefByIndex(tenantId);
                    uid = tRefIdx.parent.id;
                }
                await tenantRefByUid(uid, tenantId).set({
                    subscription: {
                        status: "canceled",
                        stripeSubscriptionId: sub.id,
                        currentPeriodEnd: admin.firestore.Timestamp.fromMillis(sub.current_period_end * 1000),
                    },
                }, { merge: true });
            }
        }
        /* ========== 4) 請求書 ========== */
        if (type === "invoice.payment_succeeded" || type === "invoice.payment_failed") {
            const inv = event.data.object;
            const customerId = inv.customer;
            // すべての uid スペースを横断検索は重い → 事前に subscription.stripeCustomerId をテナント doc に保存しているので
            // tenantIndex 全件 → 1件ずつ見るのは非効率。ここは控えめにサンプル実装として、tenantIndex を走査して最初に見つかったものに書き込み。
            const idxSnap = await db.collection("tenantIndex").get();
            for (const d of idxSnap.docs) {
                const { uid, tenantId } = d.data();
                const t = await db.collection(uid).doc(tenantId).get();
                if (t.exists && t.get("subscription.stripeCustomerId") === customerId) {
                    await db
                        .collection(uid)
                        .doc(tenantId)
                        .collection("invoices")
                        .doc(inv.id)
                        .set({
                        amount_due: inv.amount_due,
                        amount_paid: inv.amount_paid,
                        currency: (inv.currency ?? "jpy").toUpperCase(),
                        status: inv.status,
                        hosted_invoice_url: inv.hosted_invoice_url,
                        invoice_pdf: inv.invoice_pdf,
                        created: admin.firestore.Timestamp.fromMillis(inv.created * 1000),
                        period_start: admin.firestore.Timestamp.fromMillis((inv.lines?.data?.[0]?.period?.start ?? inv.created) * 1000),
                        period_end: admin.firestore.Timestamp.fromMillis((inv.lines?.data?.[0]?.period?.end ?? inv.created) * 1000),
                        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                    }, { merge: true });
                    break;
                }
            }
        }
        /* ========== 5) Connect アカウント状態 ========== */
        if (type === "account.updated") {
            const acct = event.data.object;
            try {
                const tRef = await tenantRefByStripeAccount(acct.id);
                await tRef.set({
                    connect: {
                        charges_enabled: !!acct.charges_enabled,
                        payouts_enabled: !!acct.payouts_enabled,
                        details_submitted: !!acct.details_submitted,
                        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                    },
                }, { merge: true });
            }
            catch {
                console.warn("No tenant found in tenantStripeIndex for", acct.id);
            }
        }
        /* ========== 6) 保険: PI から初期費用確定 ========== */
        if (type === "payment_intent.succeeded") {
            const pi = event.data.object;
            const kind = pi.metadata?.kind;
            const tenantId = pi.metadata?.tenantId;
            let uid = pi.metadata?.uid;
            if (kind === "initial_fee" && tenantId) {
                if (!uid) {
                    const tRefIdx = await tenantRefByIndex(tenantId);
                    uid = tRefIdx.parent.id;
                }
                const tRef = tenantRefByUid(uid, tenantId);
                await tRef.set({
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
                }, { merge: true });
            }
        }
        await docRef.set({ handled: true }, { merge: true });
        res.sendStatus(200);
        return;
    }
    catch (e) {
        console.error(e);
        res.sendStatus(500);
        return;
    }
});
/* ===================== Connect: Express（テナント直・参考） ===================== */
exports.createConnectAccountForTenant = (0, https_1.onCall)({
    region: "us-central1",
    memory: "256MiB",
    cors: [APP_ORIGIN, "http://localhost:5173"],
    secrets: ["STRIPE_SECRET_KEY"],
}, async (req) => {
    if (!req.auth)
        throw new https_1.HttpsError("unauthenticated", "auth required");
    const tenantId = req.data?.tenantId;
    if (!tenantId)
        throw new https_1.HttpsError("invalid-argument", "tenantId required");
    const stripe = stripeClient();
    // 旧: tenants/{tenantId}
    // Express 用は“グローバル”で持っている前提だったのでここは保持（必要なら uid 名空間化）
    const tRef = db.collection("tenants").doc(tenantId);
    const tSnap = await tRef.get();
    if (!tSnap.exists)
        throw new https_1.HttpsError("not-found", "tenant not found");
    const existing = tSnap.data()?.stripeAccountId;
    if (existing)
        return { stripeAccountId: existing, already: true };
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
});
exports.createAccountOnboardingLink = (0, https_1.onCall)({
    region: "us-central1",
    memory: "256MiB",
    cors: [APP_ORIGIN, "http://localhost:5173"],
    secrets: ["STRIPE_SECRET_KEY", "FRONTEND_BASE_URL"],
}, async (req) => {
    if (!req.auth)
        throw new https_1.HttpsError("unauthenticated", "auth required");
    const tenantId = req.data?.tenantId;
    if (!tenantId)
        throw new https_1.HttpsError("invalid-argument", "tenantId required");
    const t = await db.collection("tenants").doc(tenantId).get();
    const acctId = t.data()?.stripeAccountId;
    if (!acctId)
        throw new https_1.HttpsError("failed-precondition", "no stripeAccountId");
    const stripe = stripeClient();
    const BASE = process.env.FRONTEND_BASE_URL;
    const link = await stripe.accountLinks.create({
        account: acctId,
        type: "account_onboarding",
        refresh_url: `${BASE}/#/connect-refresh?t=${tenantId}`,
        return_url: `${BASE}/#/connect-return?t=${tenantId}`,
    });
    return { url: link.url };
});
/* ===================== 招待（そのまま） ===================== */
exports.inviteTenantAdmin = functions.https.onCall(async (data, context) => {
    const uid = context.auth?.uid;
    if (!uid)
        throw new functions.https.HttpsError("unauthenticated", "Sign in");
    const tenantId = data?.tenantId;
    const emailRaw = (data?.email || "").toString();
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
exports.acceptTenantAdmin = functions.https.onCall(async (data, context) => {
    const uid = context.auth?.uid;
    const userEmail = (context.auth?.token?.email || "").toLowerCase();
    if (!uid || !userEmail) {
        throw new functions.https.HttpsError("unauthenticated", "Sign-in with email");
    }
    const tenantId = data?.tenantId;
    const token = data?.token;
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
exports.revokeInvite = functions.https.onCall(async (data, context) => {
    const uid = context.auth?.uid;
    if (!uid)
        throw new functions.https.HttpsError("unauthenticated", "Sign in");
    const tenantId = data?.tenantId;
    const inviteId = data?.inviteId;
    if (!tenantId || !inviteId)
        throw new functions.https.HttpsError("invalid-argument", "bad args");
    await assertTenantAdmin(tenantId, uid);
    await db.doc(`tenants/${tenantId}/invites/${inviteId}`).update({ status: "revoked" });
    return { ok: true };
});
/* ===================== サブスク Checkout ===================== */
exports.createSubscriptionCheckout = functions
    .region("us-central1")
    .runWith({ secrets: ["STRIPE_SECRET_KEY", "FRONTEND_BASE_URL"] })
    .https.onCall(async (data, context) => {
    const uid = context.auth?.uid;
    if (!uid)
        throw new functions.https.HttpsError("unauthenticated", "Sign-in required");
    const { tenantId, plan, email, name } = (data || {});
    if (!tenantId || !plan) {
        throw new functions.https.HttpsError("invalid-argument", "tenantId and plan are required.");
    }
    const STRIPE_KEY = process.env.STRIPE_SECRET_KEY;
    const APP_BASE = process.env.FRONTEND_BASE_URL;
    const stripe = new stripe_1.default(STRIPE_KEY, { apiVersion: "2023-10-16" });
    const planDoc = await getPlanFromDb(plan);
    const purchaserEmail = email || context.auth?.token?.email;
    const customerId = await ensureCustomer(uid, tenantId, purchaserEmail, name);
    const subs = await stripe.subscriptions.list({
        customer: customerId,
        status: "all",
        limit: 10,
    });
    const hasOngoing = subs.data.some((s) => ["active", "trialing", "past_due", "unpaid"].includes(s.status));
    if (hasOngoing) {
        const portal = await stripe.billingPortal.sessions.create({
            customer: customerId,
            return_url: `${APP_BASE}/#/settings?tenant=${encodeURIComponent(tenantId)}`,
        });
        return { alreadySubscribed: true, portalUrl: portal.url };
    }
    const successUrl = `${APP_BASE}/stripe-bridge.html#event=subscribed&tenant=${encodeURIComponent(tenantId)}&plan=${encodeURIComponent(plan)}`;
    const cancelUrl = `${APP_BASE}/stripe-bridge.html#event=subscription_canceled&tenant=${encodeURIComponent(tenantId)}`;
    const session = await stripe.checkout.sessions.create({
        mode: "subscription",
        customer: customerId,
        line_items: [{ price: planDoc.stripePriceId, quantity: 1 }],
        allow_promotion_codes: true,
        subscription_data: { metadata: { tenantId, plan, uid } },
        success_url: successUrl,
        cancel_url: cancelUrl,
    });
    await upsertTenantIndex(uid, tenantId);
    return { url: session.url };
});
/* ===================== Customer Portal ===================== */
exports.openCustomerPortal = functions
    .region("us-central1")
    .runWith({ secrets: ["STRIPE_SECRET_KEY", "FRONTEND_BASE_URL"] })
    .https.onCall(async (data, context) => {
    const uid = context.auth?.uid;
    if (!uid)
        throw new functions.https.HttpsError("unauthenticated", "Sign-in required");
    const { tenantId } = (data || {});
    if (!tenantId) {
        throw new functions.https.HttpsError("invalid-argument", "tenantId is required.");
    }
    const STRIPE_KEY = process.env.STRIPE_SECRET_KEY;
    const APP_BASE = process.env.FRONTEND_BASE_URL;
    const stripe = new stripe_1.default(STRIPE_KEY, { apiVersion: "2023-10-16" });
    const tenantRef = tenantRefByUid(uid, tenantId);
    const t = (await tenantRef.get()).data();
    const customerId = t?.subscription?.stripeCustomerId;
    if (!customerId) {
        throw new functions.https.HttpsError("failed-precondition", "Stripe customer does not exist yet.");
    }
    const session = await stripe.billingPortal.sessions.create({
        customer: customerId,
        return_url: `${APP_BASE}/#/store?tenant=${encodeURIComponent(tenantId)}`,
    });
    return { url: session.url };
});
/* ===================== 請求書一覧 ===================== */
exports.listInvoices = functions
    .region("us-central1")
    .runWith({ secrets: ["STRIPE_SECRET_KEY"] })
    .https.onCall(async (data, context) => {
    const uid = context.auth?.uid;
    if (!uid)
        throw new functions.https.HttpsError("unauthenticated", "Sign-in required");
    const { tenantId, limit } = (data || {});
    if (!tenantId) {
        throw new functions.https.HttpsError("invalid-argument", "tenantId is required.");
    }
    const STRIPE_KEY = process.env.STRIPE_SECRET_KEY;
    const stripe = new stripe_1.default(STRIPE_KEY, { apiVersion: "2023-10-16" });
    const tenantRef = tenantRefByUid(uid, tenantId);
    const t = (await tenantRef.get()).data();
    const customerId = t?.subscription?.stripeCustomerId;
    if (!customerId)
        return { invoices: [] };
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
exports.upsertConnectedAccount = (0, https_1.onCall)({
    region: "us-central1",
    memory: "256MiB",
    cors: [APP_ORIGIN, "http://localhost:5173", "http://localhost:59694"],
    secrets: ["STRIPE_SECRET_KEY", "FRONTEND_BASE_URL"],
}, async (req) => {
    if (!req.auth)
        throw new https_1.HttpsError("unauthenticated", "auth required");
    const uid = req.auth.uid;
    const tenantId = req.data?.tenantId;
    const form = (req.data?.account || {});
    if (!tenantId)
        throw new https_1.HttpsError("invalid-argument", "tenantId required");
    const tRef = tenantRefByUid(uid, tenantId);
    const tDoc = await tRef.get();
    if (!tDoc.exists)
        throw new https_1.HttpsError("not-found", "tenant not found");
    const members = (tDoc.data()?.members ?? []);
    if (!members.includes(uid)) {
        throw new https_1.HttpsError("permission-denied", "not a tenant member");
    }
    const stripe = stripeClient();
    let acctId = tDoc.data()?.stripeAccountId;
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
        await tRef.set({
            stripeAccountId: acctId,
            connect: {
                charges_enabled: created.charges_enabled,
                payouts_enabled: created.payouts_enabled,
            },
        }, { merge: true });
        await upsertTenantIndex(uid, tenantId, acctId); // ★ index
    }
    const upd = {};
    if (form.businessType)
        upd.business_type = form.businessType;
    if (form.businessProfile)
        upd.business_profile = form.businessProfile;
    if (form.individual)
        upd.individual = form.individual;
    if (form.company)
        upd.company = form.company;
    if (form.bankAccountToken)
        upd.external_account = form.bankAccountToken;
    if (form.tosAccepted) {
        upd.tos_acceptance = {
            date: Math.floor(Date.now() / 1000),
            ip: req.rawRequest.headers["x-forwarded-for"]?.split(",")[0] ||
                req.rawRequest.ip,
            user_agent: req.rawRequest.get("user-agent") || undefined,
        };
    }
    const updated = await stripe.accounts.update(acctId, upd);
    const due = updated.requirements?.currently_due ?? [];
    const pastDue = updated.requirements?.past_due ?? [];
    const needsHosted = due.length > 0 || pastDue.length > 0;
    let onboardingUrl;
    if (needsHosted) {
        const BASE = process.env.FRONTEND_BASE_URL;
        const link = await stripe.accountLinks.create({
            account: acctId,
            type: "account_onboarding",
            refresh_url: `${BASE}/#/connect-refresh?t=${tenantId}`,
            return_url: `${BASE}/#/connect-return?t=${tenantId}`,
        });
        onboardingUrl = link.url;
    }
    await tRef.set({
        connect: {
            charges_enabled: updated.charges_enabled,
            payouts_enabled: updated.payouts_enabled,
            requirements: updated.requirements || null,
        },
    }, { merge: true });
    await upsertTenantIndex(uid, tenantId, acctId); // ★ index 保守
    return {
        accountId: acctId,
        chargesEnabled: updated.charges_enabled,
        payoutsEnabled: updated.payouts_enabled,
        due,
        onboardingUrl,
    };
});
/* ===================== 初期費用 Checkout ===================== */
async function getOrCreateInitialFeePrice(stripe, currency = "jpy", unitAmount = 3000, productName = "初期費用") {
    const ENV_PRICE = process.env.INITIAL_FEE_PRICE_ID;
    if (ENV_PRICE)
        return ENV_PRICE;
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
        query: `product:'${productId}' AND ` +
            `currency:'${currency}' AND ` +
            `active:'true' AND ` +
            `type:'one_time' AND ` +
            `unit_amount:'${unitAmount}'`,
        limit: 1,
    });
    if (prices.data[0])
        return prices.data[0].id;
    const price = await stripe.prices.create({
        product: productId,
        currency,
        unit_amount: unitAmount,
        metadata: { kind: "initial_fee" },
    });
    return price.id;
}
exports.createInitialFeeCheckout = functions
    .region("us-central1")
    .runWith({
    secrets: ["STRIPE_SECRET_KEY", "FRONTEND_BASE_URL", "INITIAL_FEE_PRICE_ID"],
})
    .https.onCall(async (data, context) => {
    const uid = context.auth?.uid;
    if (!uid) {
        throw new functions.https.HttpsError("unauthenticated", "Sign-in required.");
    }
    const { tenantId, email, name } = (data || {});
    if (!tenantId) {
        throw new functions.https.HttpsError("invalid-argument", "tenantId is required.");
    }
    const STRIPE_KEY = process.env.STRIPE_SECRET_KEY;
    const APP_BASE = process.env.FRONTEND_BASE_URL;
    const stripe = new stripe_1.default(STRIPE_KEY, { apiVersion: "2023-10-16" });
    const tRef = tenantRefByUid(uid, tenantId);
    const tSnap = await tRef.get();
    if (tSnap.exists && tSnap.data()?.billing?.initialFee?.status === "paid") {
        return { alreadyPaid: true };
    }
    const purchaserEmail = email || context.auth?.token?.email;
    const customerId = await ensureCustomer(uid, tenantId, purchaserEmail, name);
    const priceId = await getOrCreateInitialFeePrice(stripe);
    const successUrl = `${APP_BASE}/stripe-bridge.html#event=initial_fee_paid&tenant=${encodeURIComponent(tenantId)}`;
    const cancelUrl = `${APP_BASE}/stripe-bridge.html#event=initial_fee_canceled&tenant=${encodeURIComponent(tenantId)}`;
    const session = await stripe.checkout.sessions.create({
        mode: "payment",
        customer: customerId,
        line_items: [{ price: priceId, quantity: 1 }],
        client_reference_id: tenantId,
        payment_intent_data: { metadata: { tenantId, kind: "initial_fee", uid } },
        success_url: successUrl,
        cancel_url: cancelUrl,
    });
    await tRef.set({
        billing: {
            initialFee: {
                status: "checkout_open",
                lastSessionId: session.id,
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            },
        },
    }, { merge: true });
    await upsertTenantIndex(uid, tenantId);
    return { url: session.url };
});
