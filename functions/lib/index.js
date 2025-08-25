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
exports.listInvoices = exports.openCustomerPortal = exports.createSubscriptionCheckout = exports.revokeInvite = exports.acceptTenantAdmin = exports.inviteTenantAdmin = exports.createAccountOnboardingLink = exports.createConnectAccountForTenant = exports.stripeWebhook = exports.onTipSucceededSendMailV2 = exports.createStoreTipSessionPublic = exports.createTipSessionPublic = exports.RESEND_API_KEY = void 0;
const functions = __importStar(require("firebase-functions"));
const stripe_1 = __importDefault(require("stripe"));
const firestore_1 = require("firebase-functions/v2/firestore");
const params_1 = require("firebase-functions/params");
const admin = __importStar(require("firebase-admin"));
if (!admin.apps.length) {
    admin.initializeApp(); // 1回だけ
}
const db = admin.firestore();
exports.RESEND_API_KEY = (0, params_1.defineSecret)('RESEND_API_KEY');
/** 必須環境変数チェック（未設定ならわかりやすく失敗させる） */
function requireEnv(name) {
    const v = process.env[name];
    if (!v) {
        throw new functions.https.HttpsError("failed-precondition", `Server misconfigured: missing ${name}`);
    }
    return v;
}
function calcApplicationFee(amount, feeCfg) {
    const p = Math.max(0, Math.min(100, Math.floor(feeCfg?.percent ?? 0))); // 0..100
    const f = Math.max(0, Math.floor(feeCfg?.fixed ?? 0));
    // JPY: 小数なし最小単位
    const percentPart = Math.floor((amount * p) / 100);
    return percentPart + f;
}
/** Stripe クライアントは遅延初期化（env 未設定でのモジュールロード失敗を防ぐ） */
let _stripe = null;
function stripeClient() {
    if (_stripe)
        return _stripe;
    _stripe = new stripe_1.default(requireEnv("STRIPE_SECRET_KEY"), {
        apiVersion: "2023-10-16",
    });
    return _stripe;
}
/** 公開ページ（未ログイン）からのチップ用：Connect 宛先＋手数料対応（スタッフ宛） */
exports.createTipSessionPublic = functions.region("us-central1")
    .runWith({
    secrets: ["STRIPE_SECRET_KEY", "FRONTEND_BASE_URL"],
    memory: "256MB",
})
    .https.onCall(async (data, _ctx) => {
    const { tenantId, employeeId, amount, memo = "Tip" } = data;
    if (!tenantId || !employeeId) {
        throw new functions.https.HttpsError("invalid-argument", "tenantId/employeeId required");
    }
    if (!Number.isInteger(amount) || (amount ?? 0) <= 0 || amount > 1000000) {
        throw new functions.https.HttpsError("invalid-argument", "invalid amount");
    }
    const tRef = db.collection("tenants").doc(tenantId);
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
    // サブスクプランから手数料率を決定（feePercent があるなら優先）
    const sub = (tDoc.data()?.subscription ?? {});
    const plan = (sub.plan ?? "A").toUpperCase();
    const percent = typeof sub.feePercent === "number"
        ? sub.feePercent
        : plan === "B" ? 15 : plan === "C" ? 10 : 20;
    // 既存の calcApplicationFee を利用（固定額がなければ 0 扱い）
    const appFee = calcApplicationFee(amount, { percent, fixed: 0 });
    // tips に pending で先に作成（tipDocId を metadata へ）
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
    try {
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
    }
    catch (err) {
        throw new functions.https.HttpsError("failed-precondition", err?.message || "Stripe error", {
            source: "stripe",
            code: err?.type || "stripe_error",
        });
    }
});
/** 公開ページ（未ログイン）からのチップ用：Connect 宛先＋手数料対応（店舗宛） */
exports.createStoreTipSessionPublic = functions.region("us-central1")
    .runWith({
    secrets: ["STRIPE_SECRET_KEY", "FRONTEND_BASE_URL"],
    memory: "256MB",
})
    .https.onCall(async (data, _ctx) => {
    const { tenantId, amount, memo = "Tip to store" } = data;
    if (!tenantId) {
        throw new functions.https.HttpsError("invalid-argument", "tenantId required");
    }
    if (!Number.isInteger(amount) || (amount ?? 0) <= 0 || amount > 1000000) {
        throw new functions.https.HttpsError("invalid-argument", "invalid amount");
    }
    const tRef = db.collection("tenants").doc(tenantId);
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
    // サブスクプランから手数料率を決定
    const sub = (tDoc.data()?.subscription ?? {});
    const plan = (sub.plan ?? "A").toUpperCase();
    const percent = typeof sub.feePercent === "number"
        ? sub.feePercent
        : plan === "B" ? 15 : plan === "C" ? 10 : 20;
    const appFee = calcApplicationFee(amount, { percent, fixed: 0 });
    // 店舗宛 tip を pending で先に作成（recipient = store）
    const storeName = tDoc.data()?.name ?? tenantId;
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
    await db.collection("tenants").doc(tenantId)
        .collection("tipSessions").doc(session.id)
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
exports.onTipSucceededSendMailV2 = (0, firestore_1.onDocumentWritten)({
    region: 'us-central1',
    document: 'tenants/{tenantId}/tips/{tipId}',
    secrets: [exports.RESEND_API_KEY],
    memory: '256MiB',
    maxInstances: 10,
}, async (event) => {
    const before = event.data?.before?.data();
    const after = event.data?.after?.data();
    if (!after)
        return;
    // “succeeded” になった瞬間だけ送る
    const beforeStatus = before?.status;
    const afterStatus = after?.status;
    if (afterStatus !== 'succeeded' || beforeStatus === 'succeeded')
        return;
    await sendTipNotification(event.params.tenantId, event.params.tipId, exports.RESEND_API_KEY.value());
});
// 履歴: tenants/{tenantId}/storeDeductionHistory に
// { percent:number, fixed:number, effectiveFrom:Timestamp } を保存している想定。
// 無ければ tenants/{tenantId}.storeDeduction をフォールバック。
async function pickEffectiveRule(tenantId, at) {
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
// バックエンドでの丸めを一元化（合計を超えない・負にならない）
function splitMinor(amountMinor, percent, fixedMinor) {
    const percentPart = Math.floor(amountMinor * (Math.max(0, percent) / 100));
    const store = Math.min(Math.max(0, amountMinor), Math.max(0, percentPart + Math.max(0, fixedMinor)));
    const staff = amountMinor - store;
    return { storeAmount: store, staffAmount: staff };
}
async function sendTipNotification(tenantId, tipId, resendApiKey) {
    const db = admin.firestore();
    const tipRef = db.collection('tenants').doc(tenantId)
        .collection('tips').doc(tipId);
    const tipSnap = await tipRef.get();
    if (!tipSnap.exists)
        return;
    const tip = tipSnap.data();
    const amount = tip.amount ?? 0;
    const currency = tip.currency?.toUpperCase() ?? 'JPY';
    const recipient = tip.recipient ?? {};
    const isEmployee = recipient.type === 'employee' || !!tip.employeeId;
    // 宛先
    const to = [];
    if (isEmployee) {
        const empId = tip.employeeId ?? recipient.employeeId;
        if (empId) {
            const empSnap = await db.collection('tenants').doc(tenantId)
                .collection('employees').doc(empId).get();
            const empEmail = empSnap.get('email');
            if (empEmail)
                to.push(empEmail);
        }
    }
    else {
        const tenSnap = await db.collection('tenants').doc(tenantId).get();
        const notify = tenSnap.get('notificationEmails');
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
        console.warn('[tip mail] no recipient', { tenantId, tipId });
        return;
    }
    // 表示
    const isJPY = currency === 'JPY';
    const money = isJPY
        ? `¥${amount.toLocaleString('ja-JP')}`
        : `${amount} ${currency}`;
    const name = isEmployee
        ? (tip.employeeName ?? recipient.employeeName ?? 'スタッフ')
        : (tip.storeName ?? recipient.storeName ?? '店舗');
    const memo = tip.memo || '';
    const createdAt = tip.createdAt?.toDate?.() ?? new Date();
    const subject = isEmployee
        ? `チップを受け取りました: ${money}`
        : `店舗宛のチップ: ${money}`;
    const text = [
        `受取先: ${name}`,
        `金額: ${money}`,
        memo ? `メモ: ${memo}` : '',
        `日時: ${createdAt.toLocaleString('ja-JP')}`,
    ].filter(Boolean).join('\n');
    const html = `
  <div style="font-family: system-ui, -apple-system, Segoe UI, Roboto, Helvetica, Arial; line-height:1.6; color:#111">
    <h2 style="margin:0 0 12px">🎉 ${subject}</h2>
    <p style="margin:0 0 6px">受取先：<strong>${escapeHtml(name)}</strong></p>
    <p style="margin:0 0 6px">金額：<strong>${escapeHtml(money)}</strong></p>
    ${memo ? `<p style="margin:0 0 6px">メモ：${escapeHtml(memo)}</p>` : ''}
    <p style="margin:0 0 6px">日時：${createdAt.toLocaleString('ja-JP')}</p>
  </div>`;
    // ★ ESM ライブラリは動的 import
    const { Resend } = await Promise.resolve().then(() => __importStar(require('resend')));
    const resend = new Resend(resendApiKey);
    await resend.emails.send({
        from: 'YourPay 通知 <sendtip_app@appfromkomeda.jp>', // Resendで認証済みドメインに置換
        to,
        subject,
        text,
        html,
    });
    await tipRef.set({ notification: { emailedAt: admin.firestore.FieldValue.serverTimestamp(), to } }, { merge: true });
}
function escapeHtml(s) {
    return s.replace(/[&<>'"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;' }[c]));
}
const https_1 = require("firebase-functions/v2/https");
const crypto = __importStar(require("crypto"));
const APP_ORIGIN = 'https://venerable-mermaid-fcf8c8.netlify.app';
function sha256(s) {
    return crypto.createHash('sha256').update(s).digest('hex');
}
async function assertTenantAdmin(tenantId, uid) {
    // members/{uid}.role == 'admin' or tenant.memberUids includes uid
    const mem = await db.doc(`tenants/${tenantId}/members/${uid}`).get();
    if (mem.exists && (mem.data()?.role === 'admin'))
        return;
    const t = await db.doc(`tenants/${tenantId}`).get();
    const arr = (t.data()?.memberUids || []);
    if (arr.includes(uid))
        return;
    throw new functions.https.HttpsError('permission-denied', 'Not tenant admin');
}
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
    // 通常 / Connect 両対応の検証
    const secrets = [
        process.env.STRIPE_WEBHOOK_SECRET,
        process.env.STRIPE_CONNECT_WEBHOOK_SECRET,
    ].filter(Boolean);
    let event = null;
    for (const secret of secrets) {
        try {
            event = stripe.webhooks.constructEvent(
            // Firebase Functions は rawBody を提供
            // eslint-disable-next-line @typescript-eslint/no-explicit-any
            req.rawBody, sig, secret);
            break;
        }
        catch {
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
        // 1) Checkout 完了
        if (type === "checkout.session.completed") {
            const session = event.data.object;
            // サブスク（Checkout）
            if (session.mode === "subscription") {
                const tenantId = session.metadata?.tenantId;
                const plan = session.metadata?.plan;
                const subscriptionId = session.subscription;
                const customerId = session.customer ?? undefined;
                if (!tenantId || !subscriptionId) {
                    console.error("subscription checkout completed but missing tenantId or subscriptionId");
                }
                else {
                    const sub = await stripe.subscriptions.retrieve(subscriptionId);
                    // オプション: プラン定義から feePercent を拾う
                    let feePercent;
                    if (plan) {
                        const planSnap = await db.doc(`billing/plans/${plan}`).get();
                        feePercent = planSnap.exists
                            ? planSnap.data()?.feePercent
                            : undefined;
                    }
                    await db
                        .collection("tenants")
                        .doc(tenantId)
                        .set({
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
                return; // サブスクはここで終了
            }
            // チップ決済（mode === "payment"）
            const sid = session.id;
            const tenantId = session.metadata?.tenantId;
            const employeeId = session.metadata?.employeeId;
            let employeeName = session.metadata?.employeeName;
            const payIntentId = session.payment_intent;
            // Stripe の作成時刻を Firestore Timestamp に（なければイベント作成時刻）
            const stripeCreatedSec = session.created ?? event.created;
            const createdAtTs = admin.firestore.Timestamp.fromMillis((stripeCreatedSec ?? Math.floor(Date.now() / 1000)) * 1000);
            if (!tenantId) {
                console.error("checkout.session.completed: missing tenantId in metadata");
            }
            else {
                const tRef = db.collection("tenants").doc(tenantId);
                await tRef
                    .collection("tipSessions")
                    .doc(sid)
                    .set({
                    status: "paid",
                    paidAt: admin.firestore.FieldValue.serverTimestamp(),
                    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                }, { merge: true });
                const tipDocId = session.metadata?.tipDocId ||
                    payIntentId ||
                    sid;
                let storeName = session.metadata?.storeName;
                if (!storeName) {
                    const tSnap = await tRef.get();
                    storeName =
                        (tSnap.exists && tSnap.data()?.name) || "Store";
                }
                if (employeeId && !employeeName) {
                    const eSnap = await tRef
                        .collection("employees")
                        .doc(employeeId)
                        .get();
                    employeeName =
                        (eSnap.exists && eSnap.data()?.name) || "Staff";
                }
                const recipient = employeeId
                    ? {
                        type: "employee",
                        employeeId,
                        employeeName: employeeName || "Staff",
                    }
                    : { type: "store", storeName: storeName };
                const tipRef = tRef.collection("tips").doc(tipDocId);
                const tipSnap = await tipRef.get();
                const existingCreatedAt = tipSnap.exists
                    ? tipSnap.data()?.createdAt
                    : null;
                // まずコア情報を保存（createdAt は Stripe の確定時刻で固定）
                await tipRef.set({
                    tenantId,
                    sessionId: sid,
                    amount: session.amount_total ?? 0, // 最小通貨単位
                    currency: (session.currency ?? "jpy").toUpperCase(),
                    status: "succeeded",
                    stripePaymentIntentId: payIntentId ?? "",
                    recipient,
                    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                    createdAt: existingCreatedAt ?? createdAtTs,
                }, { merge: true });
                // すでに split 済みかどうかチェック（冪等）
                const tipAfter = await tipRef.get();
                const alreadySplit = !!tipAfter.data()?.split?.storeAmount;
                if (!alreadySplit) {
                    // 当時の控除ルールで split を焼き込み
                    const eff = await pickEffectiveRule(tenantId, createdAtTs.toDate());
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
                // 決済に対する実際のStripe手数料とアプリ手数料を保存し、正味額も保存
                try {
                    if (payIntentId) {
                        const pi = await stripe.paymentIntents.retrieve(payIntentId, {
                            expand: ["latest_charge.balance_transaction"],
                        });
                        const latestCharge = pi.latest_charge || null;
                        const bt = latestCharge?.balance_transaction;
                        const stripeFee = bt?.fee ?? 0; // 最小単位
                        const stripeFeeCurrency = bt?.currency?.toUpperCase() ??
                            (session.currency ?? "jpy").toUpperCase();
                        // Destination charge の場合、charge.application_fee_amount に入る
                        const appFeeAmount = latestCharge?.application_fee_amount ?? 0;
                        // split から店舗控除を取得（なければ0）
                        const splitNow = (await tipRef.get()).data()?.split ?? {};
                        const storeCut = splitNow.storeAmount ?? 0;
                        const gross = (session.amount_total ?? 0);
                        const isStaff = !!employeeId;
                        // 仕様:
                        // 店舗宛て: 店舗にくるお金 = gross - appFee - stripeFee
                        // スタッフ宛て: スタッフに渡すお金 = gross - appFee - stripeFee - storeCut
                        //               店舗側取り分(控除分)は storeCut
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
        // 2) Checkout セッションのその他
        if (type === "checkout.session.expired") {
            const session = event.data.object;
            await db
                .collection("tipSessions")
                .doc(session.id)
                .set({
                status: "expired",
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });
        }
        if (type === "checkout.session.async_payment_failed") {
            const session = event.data.object;
            await db
                .collection("tipSessions")
                .doc(session.id)
                .set({
                status: "failed",
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });
        }
        // 3) 購読（作成/更新）
        if (type === "customer.subscription.created" ||
            type === "customer.subscription.updated") {
            const sub = event.data.object;
            const tenantId = sub.metadata?.tenantId;
            const plan = sub.metadata?.plan;
            if (tenantId) {
                let feePercent;
                if (plan) {
                    const planSnap = await db.doc(`billing/plans/${plan}`).get();
                    feePercent = planSnap.exists
                        ? planSnap.data()?.feePercent
                        : undefined;
                }
                await db
                    .collection("tenants")
                    .doc(tenantId)
                    .set({
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
        // 3) 購読（削除）
        if (type === "customer.subscription.deleted") {
            const sub = event.data.object;
            const tenantId = sub.metadata?.tenantId;
            if (tenantId) {
                await db
                    .collection("tenants")
                    .doc(tenantId)
                    .set({
                    subscription: {
                        status: "canceled",
                        stripeSubscriptionId: sub.id,
                        currentPeriodEnd: admin.firestore.Timestamp.fromMillis(sub.current_period_end * 1000),
                    },
                }, { merge: true });
            }
        }
        // 4) 請求書（決済成功/失敗）
        if (type === "invoice.payment_succeeded" ||
            type === "invoice.payment_failed") {
            const inv = event.data.object;
            const customerId = inv.customer;
            const qs = await db
                .collection("tenants")
                .where("subscription.stripeCustomerId", "==", customerId)
                .limit(1)
                .get();
            if (!qs.empty) {
                const tRef = qs.docs[0].ref;
                await tRef
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
                    period_start: admin.firestore.Timestamp.fromMillis((inv.lines?.data?.[0]?.period?.start ??
                        inv.created) * 1000),
                    period_end: admin.firestore.Timestamp.fromMillis((inv.lines?.data?.[0]?.period?.end ??
                        inv.created) * 1000),
                    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                }, { merge: true });
            }
        }
        // 5) Connect アカウント状態の同期
        if (type === "account.updated") {
            const acct = event.data.object;
            const qs = await db
                .collection("tenants")
                .where("stripeAccountId", "==", acct.id)
                .limit(1)
                .get();
            if (!qs.empty) {
                const tRef = qs.docs[0].ref;
                await tRef.set({
                    connect: {
                        charges_enabled: !!acct.charges_enabled,
                        payouts_enabled: !!acct.payouts_enabled,
                        details_submitted: !!acct.details_submitted,
                        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
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
exports.createConnectAccountForTenant = (0, https_1.onCall)({
    region: "us-central1",
    memory: "256MiB",
    cors: ["https://venerable-mermaid-fcf8c8.netlify.app", "http://localhost:5173"],
    secrets: ["STRIPE_SECRET_KEY"],
}, async (req) => {
    if (!req.auth)
        throw new https_1.HttpsError("unauthenticated", "auth required");
    const tenantId = req.data?.tenantId;
    if (!tenantId)
        throw new https_1.HttpsError("invalid-argument", "tenantId required");
    const tRef = db.collection("tenants").doc(tenantId);
    const tSnap = await tRef.get();
    if (!tSnap.exists)
        throw new https_1.HttpsError("not-found", "tenant not found");
    const existing = tSnap.data()?.stripeAccountId;
    if (existing)
        return { stripeAccountId: existing, already: true };
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
});
exports.createAccountOnboardingLink = (0, https_1.onCall)({
    region: "us-central1",
    memory: "256MiB",
    cors: ["https://venerable-mermaid-fcf8c8.netlify.app", "http://localhost:5173"],
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
/** 1) 招待を作成してメール送信 */
exports.inviteTenantAdmin = functions.https.onCall(async (data, context) => {
    const uid = context.auth?.uid;
    if (!uid)
        throw new functions.https.HttpsError('unauthenticated', 'Sign in');
    const tenantId = data?.tenantId;
    const emailRaw = (data?.email || '').toString();
    const emailLower = emailRaw.trim().toLowerCase();
    if (!tenantId || !emailLower.includes('@')) {
        throw new functions.https.HttpsError('invalid-argument', 'bad tenantId/email');
    }
    await assertTenantAdmin(tenantId, uid);
    // token作成（メールに入れるのは生token、DBにはhashだけ保存）
    const token = crypto.randomBytes(32).toString('hex');
    const tokenHash = sha256(token);
    const expiresAt = admin.firestore.Timestamp.fromDate(new Date(Date.now() + 1000 * 60 * 60 * 24 * 7) // 7日
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
exports.acceptTenantAdmin = functions.https.onCall(async (data, context) => {
    const uid = context.auth?.uid;
    const userEmail = (context.auth?.token?.email || '').toLowerCase();
    if (!uid || !userEmail) {
        throw new functions.https.HttpsError('unauthenticated', 'Sign in with email');
    }
    const tenantId = data?.tenantId;
    const token = data?.token;
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
exports.revokeInvite = functions.https.onCall(async (data, context) => {
    const uid = context.auth?.uid;
    if (!uid)
        throw new functions.https.HttpsError('unauthenticated', 'Sign in');
    const tenantId = data?.tenantId;
    const inviteId = data?.inviteId;
    if (!tenantId || !inviteId)
        throw new functions.https.HttpsError('invalid-argument', 'bad args');
    await assertTenantAdmin(tenantId, uid);
    await db.doc(`tenants/${tenantId}/invites/${inviteId}`).update({ status: 'revoked' });
    return { ok: true };
});
async function getTenantRef(tenantId) {
    return db.collection("tenants").doc(tenantId);
}
async function getPlanFromDb(planId) {
    // ① /billingPlans/{planId} というコレクションに各プランDoc
    let snap = await db.collection("billingPlans").doc(planId).get();
    if (snap.exists)
        return snap.data();
    // ② /billing/plans というDocに { A: {...}, B: {...} } のようなフィールドで格納
    snap = await db.collection("billing").doc("plans").get();
    if (snap.exists) {
        const data = snap.data() || {};
        const candidate = (data.plans && data.plans[planId]) || // {plans: {A:{}, B:{}}}
            data[planId]; // {A:{}, B:{}} を直置き
        if (candidate && candidate.stripePriceId)
            return candidate;
    }
    // ③ /billing/plans/plans/{planId}（サブコレクションにDoc）※必要なら
    snap = await db.collection("billing").doc("plans").collection("plans").doc(planId).get();
    if (snap.exists)
        return snap.data();
    throw new functions.https.HttpsError("not-found", `Plan "${planId}" not found in billingPlans/{id}, billing/plans(plans map), or billing/plans/plans/{id}.`);
}
// 既存 or 新規の Stripe Customer を返し、tenant に保存
async function ensureCustomer(tenantId, email, name) {
    const stripe = new stripe_1.default(requireEnv("STRIPE_SECRET_KEY"), {
        apiVersion: "2023-10-16",
    });
    const tenantRef = await getTenantRef(tenantId);
    const tSnap = await tenantRef.get();
    const tData = (tSnap.data() || {});
    const sub = tData.subscription || {};
    if (sub.stripeCustomerId)
        return sub.stripeCustomerId;
    const customer = await stripe.customers.create({
        email,
        name,
        metadata: { tenantId }
    });
    await tenantRef.set({
        subscription: { ...(sub || {}), stripeCustomerId: customer.id }
    }, { merge: true });
    return customer.id;
}
// ============ onCall: Checkout セッション生成（定期課金） ============
// data: { tenantId: string, plan: string, email?: string, name?: string }
exports.createSubscriptionCheckout = functions
    .region("us-central1")
    .runWith({ secrets: ["STRIPE_SECRET_KEY", "FRONTEND_BASE_URL"] }) // ★追加
    .https.onCall(async (data, context) => {
    const { tenantId, plan, email, name } = (data || {});
    if (!tenantId || !plan) {
        throw new functions.https.HttpsError("invalid-argument", "tenantId and plan are required.");
    }
    // Secret Manager から注入された環境変数を直接読む
    const STRIPE_KEY = process.env.STRIPE_SECRET_KEY;
    const APP_ORIGIN = process.env.FRONTEND_BASE_URL;
    if (!STRIPE_KEY || !APP_ORIGIN) {
        throw new functions.https.HttpsError("failed-precondition", "Missing required secrets.");
    }
    const stripe = new stripe_1.default(STRIPE_KEY, { apiVersion: "2023-10-16" });
    // 以降は既存ロジックそのまま（抜粋）
    const planDoc = await getPlanFromDb(plan);
    const purchaserEmail = email || context.auth?.token?.email;
    const customerId = await ensureCustomer(tenantId, purchaserEmail, name);
    const successUrl = `${APP_ORIGIN}/#/settings?tenant=${encodeURIComponent(tenantId)}&checkout=success`;
    const cancelUrl = `${APP_ORIGIN}/#/settings?tenant=${encodeURIComponent(tenantId)}&checkout=cancel`;
    // 既存のサブスクがあるか Stripe に問い合わせ（価格で縛りたいなら price フィルタも）
    const subs = await stripe.subscriptions.list({
        customer: customerId,
        status: 'all', // 'active' だけだと見落とす場合がある
        limit: 10,
    });
    // 1契約までのルール：有効系ステータスがあるなら新規チェックアウトを拒否
    const hasOngoing = subs.data.some(s => ['active', 'trialing', 'past_due', 'unpaid'].includes(s.status));
    if (hasOngoing) {
        // 既存客は Checkout させず、Billing Portal へ誘導（カード変更/請求履歴/解約/プラン変更）
        const portal = await stripe.billingPortal.sessions.create({
            customer: customerId,
            return_url: `${APP_ORIGIN}/#/settings?tenant=${encodeURIComponent(tenantId)}`
        });
        // front 側で「すでに契約中です」と案内しつつ、portal.url を開く
        return { alreadySubscribed: true, portalUrl: portal.url };
    }
    const session = await stripe.checkout.sessions.create({
        mode: "subscription",
        customer: customerId,
        line_items: [{ price: planDoc.stripePriceId, quantity: 1 }],
        allow_promotion_codes: true,
        subscription_data: { metadata: { tenantId, plan } },
        success_url: successUrl,
        cancel_url: cancelUrl,
    });
    return { url: session.url };
});
// ============ onCall: Billing Portal（カード変更・請求履歴表示） ============
exports.openCustomerPortal = functions
    .region("us-central1")
    .runWith({ secrets: ["STRIPE_SECRET_KEY", "FRONTEND_BASE_URL"] }) // ★追加
    .https.onCall(async (data, context) => {
    const { tenantId } = (data || {});
    if (!tenantId) {
        throw new functions.https.HttpsError("invalid-argument", "tenantId is required.");
    }
    const STRIPE_KEY = process.env.STRIPE_SECRET_KEY;
    const APP_ORIGIN = process.env.FRONTEND_BASE_URL;
    if (!STRIPE_KEY || !APP_ORIGIN) {
        throw new functions.https.HttpsError("failed-precondition", "Missing required secrets.");
    }
    const stripe = new stripe_1.default(STRIPE_KEY, { apiVersion: "2023-10-16" });
    const tenantRef = await getTenantRef(tenantId);
    const t = (await tenantRef.get()).data();
    const customerId = t?.subscription?.stripeCustomerId;
    if (!customerId) {
        throw new functions.https.HttpsError("failed-precondition", "Stripe customer does not exist yet.");
    }
    const session = await stripe.billingPortal.sessions.create({
        customer: customerId,
        return_url: `${APP_ORIGIN}/#/settings?tenant=${encodeURIComponent(tenantId)}`
    });
    return { url: session.url };
});
// ============ onCall: 請求書一覧（アプリ内でも履歴確認したい場合） ============
exports.listInvoices = functions
    .region("us-central1")
    .runWith({ secrets: ["STRIPE_SECRET_KEY"] }) // ★追加
    .https.onCall(async (data, context) => {
    const { tenantId, limit } = (data || {});
    if (!tenantId) {
        throw new functions.https.HttpsError("invalid-argument", "tenantId is required.");
    }
    const STRIPE_KEY = process.env.STRIPE_SECRET_KEY;
    if (!STRIPE_KEY) {
        throw new functions.https.HttpsError("failed-precondition", "Missing STRIPE_SECRET_KEY.");
    }
    const stripe = new stripe_1.default(STRIPE_KEY, { apiVersion: "2023-10-16" });
    const tenantRef = await getTenantRef(tenantId);
    const t = (await tenantRef.get()).data();
    const customerId = t?.subscription?.stripeCustomerId;
    if (!customerId)
        return { invoices: [] };
    const resp = await stripe.invoices.list({
        customer: customerId,
        limit: Math.min(Math.max(limit ?? 12, 1), 50),
    });
    const invoices = resp.data.map(inv => ({
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
