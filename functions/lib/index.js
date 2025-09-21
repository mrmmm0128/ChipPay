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
exports.createConnectAccountLink = exports.createCustomerPortalSession = exports.createInitialFeeCheckout = exports.upsertConnectedAccount = exports.listInvoices = exports.changeSubscriptionPlan = exports.createSubscriptionCheckout = exports.cancelTenantAdminInvite = exports.acceptTenantAdminInvite = exports.inviteTenantAdmin = exports.stripeWebhook = exports.onTipSucceededSendMailV2 = exports.createStoreTipSessionPublic = exports.createTipSessionPublic = exports.setAdminByEmail = exports.agentLogin = exports.adminSetAgencyPassword = exports.RESEND_API_KEY = void 0;
exports.assertTenantAdmin = assertTenantAdmin;
exports.sendInvoiceNotificationByCustomerId = sendInvoiceNotificationByCustomerId;
/* eslint-disable @typescript-eslint/no-explicit-any */
const functions = __importStar(require("firebase-functions"));
const https_1 = require("firebase-functions/v2/https");
const firestore_1 = require("firebase-functions/v2/firestore");
const params_1 = require("firebase-functions/params");
const admin = __importStar(require("firebase-admin"));
const stripe_1 = __importDefault(require("stripe"));
const crypto = __importStar(require("crypto"));
const bcrypt = __importStar(require("bcryptjs"));
const logger = __importStar(require("firebase-functions/logger"));
if (!admin.apps.length)
    admin.initializeApp();
const db = admin.firestore();
/* ===================== Secrets / Const ===================== */
exports.RESEND_API_KEY = (0, params_1.defineSecret)("RESEND_API_KEY");
const APP_ORIGIN = "https://venerable-mermaid-fcf8c8.netlify.app";
const ALLOWED_ORIGINS = [
    APP_ORIGIN,
].filter(Boolean);
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
/** 代理店パスワード設定（CORS対応・v2 onCall） */
exports.adminSetAgencyPassword = (0, https_1.onCall)({
    region: 'us-central1',
    memory: '256MiB',
    cors: ALLOWED_ORIGINS.length ? ALLOWED_ORIGINS : true, // 何も無ければ全許可
}, async (req) => {
    const agentId = String(req.data?.agentId ?? '').trim();
    const newPassword = String(req.data?.password ?? '');
    if (!agentId || !newPassword) {
        throw new https_1.HttpsError('invalid-argument', 'agentId/password required');
    }
    if (newPassword.length < 8) {
        throw new https_1.HttpsError('invalid-argument', 'password too short (>=8)');
    }
    const ref = db.collection('agencies').doc(agentId);
    const snap = await ref.get();
    if (!snap.exists)
        throw new https_1.HttpsError('not-found', 'agency not found');
    const salt = await bcrypt.genSalt(10);
    const passwordHash = await bcrypt.hash(newPassword, salt);
    await ref.set({
        passwordHash,
        passwordSetAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });
    return { ok: true };
});
exports.agentLogin = (0, https_1.onCall)({
    region: "us-central1",
    memory: "256MiB",
    // 許可するオリジン
    cors: [APP_ORIGIN, "http://localhost:5173", "http://localhost:5000"],
}, async (req) => {
    try {
        const rawCode = (req.data?.code || "").toString().trim();
        const password = (req.data?.password || "").toString();
        if (!rawCode || !password) {
            throw new https_1.HttpsError("invalid-argument", "code/password required");
        }
        // ※ 必要なら UID として安全な文字に正規化（任意）
        //   大文字小文字ゆらぎや空白・記号対策。要件に合わせて調整。
        const code = rawCode.toLowerCase();
        // code はユニーク想定
        const qs = await db.collection("agencies").where("code", "==", rawCode).limit(1).get();
        if (qs.empty)
            throw new https_1.HttpsError("not-found", "agency not found");
        const doc = qs.docs[0];
        const agentId = doc.id;
        const m = (doc.data() || {});
        if ((m.status || "active") !== "active") {
            throw new https_1.HttpsError("failed-precondition", "agency suspended");
        }
        const hash = m.passwordHash || "";
        if (!hash)
            throw new https_1.HttpsError("failed-precondition", "password not set");
        const ok = await bcrypt.compare(password, hash);
        if (!ok)
            throw new https_1.HttpsError("permission-denied", "invalid credentials");
        // ★ ここを code に
        const agentUid = code; // ← UID = code（要求通り）
        // ついでに表示名やカスタムクレームも付与
        const additionalClaims = {
            role: "agent",
            agentId,
            code: rawCode, // 元の表記も残したい場合
        };
        // ユーザーの存在保証（任意：DisplayName セット等）
        try {
            await admin.auth().getUser(agentUid);
        }
        catch {
            await admin.auth().createUser({
                uid: agentUid,
                displayName: m.name || `Agent ${rawCode}`,
            });
        }
        const token = await admin.auth().createCustomToken(agentUid, additionalClaims);
        await doc.ref.set({ lastLoginAt: admin.firestore.FieldValue.serverTimestamp() }, { merge: true });
        return {
            token,
            uid: agentUid, // ← 返却しておくとフロントで扱いやすい
            agentId,
            agentName: m.name || "",
            agent: true
        };
    }
    catch (err) {
        logger.error("agentLogin failed", err);
        if (err instanceof https_1.HttpsError)
            throw err;
        throw new https_1.HttpsError("internal", err?.message ?? "internal error");
    }
});
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
async function assertTenantAdmin(tenantId, uid) {
    // ルート: {collection: <uid>, doc: <tenantId>}
    const tRef = db.collection(uid).doc(tenantId);
    const tSnap = await tRef.get();
    if (!tSnap.exists) {
        throw new functions.https.HttpsError("not-found", "Tenant not found");
    }
    const data = tSnap.data() || {};
    const members = (data.members ?? []);
    if (Array.isArray(members) && members.length) {
        const inMembers = members.some((m) => {
            if (typeof m === "string") {
                // ["uid1","uid2",...] 形式
                return m === uid;
            }
            if (m && typeof m === "object") {
                // [{uid:"...", role:"admin"}, ...] 形式も許容
                const mid = m.uid ?? m.id ?? m.userId;
                const role = String(m.role ?? "admin").toLowerCase();
                // 役割を使うならここで admin/owner 判定
                return mid === uid && (role === "admin" || role === "owner");
            }
            return false;
        });
        if (inMembers)
            return;
    }
    throw new functions.https.HttpsError("permission-denied", "Not tenant admin");
}
const OWNER_EMAILS = new Set(["appfromkomeda@gmail.com"]); // 自分の運営アカウントに置換
exports.setAdminByEmail = functions
    .region("us-central1")
    .https.onCall(async (data, context) => {
    const callerEmail = context.auth?.token?.email;
    if (!callerEmail || !OWNER_EMAILS.has(callerEmail)) {
        throw new functions.https.HttpsError("permission-denied", "not allowed");
    }
    const email = data.email?.trim();
    const value = data.value ?? true;
    if (!email) {
        throw new functions.https.HttpsError("invalid-argument", "email required");
    }
    const user = await admin.auth().getUserByEmail(email);
    const claims = user.customClaims || {};
    claims.admin = value;
    await admin.auth().setCustomUserClaims(user.uid, claims);
    return { ok: true, uid: user.uid, email, admin: value };
});
async function pickEffectiveRule(tenantId, at, uid) {
    const histSnap = await db
        .collection(uid)
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
    const cur = await db.collection(uid).doc(tenantId).get();
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
function cleanId(v) {
    return typeof v === "string" && v.trim() ? v.trim() : undefined;
}
async function ensureCustomer(uid, tenantId, email, name) {
    const stripe = new stripe_1.default(requireEnv("STRIPE_SECRET_KEY"), {
        apiVersion: "2023-10-16",
    });
    const tenantRef = tenantRefByUid(uid, tenantId);
    const tSnap = await tenantRef.get();
    const tData = (tSnap.data() || {});
    const rootId = cleanId(tData.customerId);
    const subId = cleanId(tData.subscription?.stripeCustomerId);
    // 1) root（正）にある → 返す＆subscription に同期
    if (rootId) {
        if (subId !== rootId) {
            await tenantRef.set({ subscription: { ...(tData.subscription || {}), stripeCustomerId: rootId } }, { merge: true });
        }
        await upsertTenantIndex(uid, tenantId);
        const cusIdRef = db.collection("uidByCustomerId").doc(rootId);
        await cusIdRef.set({
            uid: uid, tenantId: tenantId, email: email
        }, { merge: true });
        return rootId;
    }
    // 2) root 無くて subscription にある → root へ移行保存して返す
    if (subId) {
        await tenantRef.set({
            customerId: subId,
        }, { merge: true });
        await upsertTenantIndex(uid, tenantId);
        const cusIdRef = db.collection("uidByCustomerId").doc(subId);
        await cusIdRef.set({
            uid: uid, tenantId: tenantId, email: email
        }, { merge: true });
        return subId;
    }
    else { // 3) どちらにも無い → Stripe作成 → 両方へ保存
        const customer = await stripe.customers.create({
            email,
            name,
            metadata: { tenantId, uid },
        });
        await tenantRef.set({
            customerId: customer.id, // ← 正
            subscription: { ...(tData.subscription || {}), stripeCustomerId: customer.id }, // ← ミラー
        }, { merge: true });
        const cusIdRef = db.collection("uidByCustomerId").doc(customer.id);
        await cusIdRef.set({
            uid: uid, tenantId: tenantId, email: email
        }, { merge: true });
        await upsertTenantIndex(uid, tenantId);
        return customer.id;
    }
}
exports.createTipSessionPublic = functions
    .region("us-central1")
    .runWith({
    secrets: ["STRIPE_SECRET_KEY", "FRONTEND_BASE_URL"],
    memory: "256MB",
})
    .https.onCall(async (data) => {
    const { tenantId, employeeId, amount, memo = "Tip", payerMessage } = data;
    if (!tenantId || !employeeId) {
        throw new functions.https.HttpsError("invalid-argument", "tenantId/employeeId required");
    }
    if (!Number.isInteger(amount) || (amount ?? 0) <= 0 || amount > 1000000) {
        throw new functions.https.HttpsError("invalid-argument", "invalid amount");
    }
    // uid を逆引きして uid/{tenantId} を参照
    const tRef = await tenantRefByIndex(tenantId);
    const uid = tRef.parent.id;
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
    const tenantName = tDoc.data()?.name ?? "";
    const sub = (tDoc.data()?.subscription ?? {});
    const plan = (sub.plan ?? "A").toUpperCase();
    const percent = typeof sub.feePercent === "number" ? sub.feePercent : plan === "B" ? 15 : plan === "C" ? 10 : 20;
    const appFee = calcApplicationFee(amount, { percent, fixed: 0 });
    const tipRef = tRef.collection("tips").doc();
    await tipRef.set({
        tenantId,
        employeeId,
        amount,
        payerMessage: payerMessage,
        currency: "JPY",
        status: "pending",
        recipient: { type: "employee", employeeId, employeeName },
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    const stripe = stripeClient();
    const FRONTEND_BASE_URL = requireEnv("FRONTEND_BASE_URL");
    // ▼ ここがポイント：完了ページ(TipCompletePage)にそのまま着地
    const successUrl = `${FRONTEND_BASE_URL}#/p` +
        `?t=${encodeURIComponent(tenantId)}` +
        `&thanks=true` +
        `&amount=${encodeURIComponent(String(amount))}` +
        `&employeeName=${encodeURIComponent(employeeName)}` +
        `&tenantName=${encodeURIComponent(tenantName)}&u=${uid}`;
    const cancelUrl = `${FRONTEND_BASE_URL}#/p` +
        `?t=${encodeURIComponent(tenantId)}` +
        `&canceled=true`;
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
        success_url: successUrl,
        cancel_url: cancelUrl,
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
    return { checkoutUrl: session.url, sessionId: session.id, tipDocId: tipRef.id };
});
exports.createStoreTipSessionPublic = functions
    .region("us-central1")
    .runWith({
    secrets: ["STRIPE_SECRET_KEY", "FRONTEND_BASE_URL"],
    memory: "256MB",
})
    .https.onCall(async (data) => {
    const { tenantId, amount, memo = "Tip to store" } = data;
    if (!tenantId)
        throw new functions.https.HttpsError("invalid-argument", "tenantId required");
    if (!Number.isInteger(amount) || (amount ?? 0) <= 0 || amount > 1000000) {
        throw new functions.https.HttpsError("invalid-argument", "invalid amount");
    }
    const tRef = await tenantRefByIndex(tenantId);
    const tDoc = await tRef.get();
    if (!tDoc.exists || tDoc.data().status !== "active") {
        throw new functions.https.HttpsError("failed-precondition", "Tenant suspended or not found");
    }
    const acctId = tDoc.data()?.stripeAccountId;
    if (!acctId)
        throw new functions.https.HttpsError("failed-precondition", "Store not connected to Stripe");
    const chargesEnabled = !!tDoc.data()?.connect?.charges_enabled;
    if (!chargesEnabled) {
        throw new functions.https.HttpsError("failed-precondition", "Store Stripe account is not ready (charges_disabled)");
    }
    const sub = (tDoc.data()?.subscription ?? {});
    const plan = (sub.plan ?? "A").toUpperCase();
    const percent = typeof sub.feePercent === "number" ? sub.feePercent : (plan === "B" ? 15 : plan === "C" ? 10 : 20);
    const appFee = calcApplicationFee(amount, { percent, fixed: 0 });
    const storeName = tDoc.data()?.name ?? tenantId;
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
    // === ここで URL を関数内で完成させる ===
    const BASE = requireEnv("FRONTEND_BASE_URL").replace(/\/+$/, "");
    const successParams = new URLSearchParams({
        t: tenantId,
        thanks: "true",
        tenantName: storeName, // 表示用（任意）
        amount: String(amount), // 表示用（任意）
    }).toString();
    const cancelParams = new URLSearchParams({
        t: tenantId,
        canceled: "true",
        tenantName: storeName, // 表示用（任意）
    }).toString();
    const successUrl = `${BASE}#/p?${successParams}`;
    const cancelUrl = `${BASE}#/p?${cancelParams}`;
    const session = await stripe.checkout.sessions.create({
        mode: "payment",
        payment_method_types: ["card", "link"],
        line_items: [
            {
                price_data: {
                    currency: "jpy",
                    product_data: { name: memo || `Tip to store ${storeName}` },
                    unit_amount: amount,
                },
                quantity: 1,
            },
        ],
        success_url: successUrl,
        cancel_url: cancelUrl,
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
const toUpperCurrency = (c) => typeof c === "string" ? c.toUpperCase() : "JPY";
const safeInt = (n) => typeof n === "number" && Number.isFinite(n) ? Math.trunc(n) : 0;
const fmtMoney = (amt, ccy) => ccy === "JPY" ? `¥${Number(amt || 0).toLocaleString("ja-JP")}` : `${amt} ${ccy}`;
async function sendTipNotification(tenantId, tipId, resendApiKey, uid) {
    // ベースURL（管理者ログイン）
    const APP_BASE = process.env.FRONTEND_BASE_URL ?? process.env.APP_BASE ?? "";
    // ------- tips ドキュメント（計算済みの内訳が入っている想定） -------
    const tipRef = db.collection(uid).doc(tenantId).collection("tips").doc(tipId);
    const tipSnap = await tipRef.get();
    if (!tipSnap.exists)
        return;
    const tip = tipSnap.data() ?? {};
    // -------- 金額・通貨と内訳（既に保存済みの値を使う） --------
    const currency = toUpperCurrency(tip.currency);
    const grossAmount = safeInt(tip.amount); // 元金（チップ総額）
    const fees = (tip.fees ?? {});
    const net = (tip.net ?? {});
    const stripeFee = safeInt(fees?.stripe?.amount);
    const platformFee = safeInt(fees?.platform);
    const storeDeduct = safeInt(net?.toStore);
    const money = (n) => fmtMoney(n, currency);
    // -------- 店舗情報 / 表示名 --------
    const tenSnap = await db.collection(uid).doc(tenantId).get();
    const tenantName = tenSnap.get("name") ||
        tenSnap.get("tenantName") ||
        "店舗";
    const isEmployee = (tip.recipient?.type === "employee") || Boolean(tip.employeeId);
    const employeeName = tip.employeeName ||
        tip.recipient?.employeeName ||
        "スタッフ";
    const displayName = isEmployee
        ? employeeName
        : (tip.storeName ||
            tip.recipient?.storeName ||
            tenantName);
    // -------- 送信先の収集（重複排除） --------
    const toSet = new Set();
    // a) 宛先（従業員 or 店舗）
    if (isEmployee) {
        const empId = tip.employeeId ||
            tip.recipient?.employeeId;
        if (empId) {
            try {
                const empSnap = await db.collection(uid).doc(tenantId)
                    .collection("employees").doc(empId).get();
                const em = empSnap.get("email");
                if (isLikelyEmail(em))
                    toSet.add(em.trim());
            }
            catch { }
        }
    }
    else {
        const storeEmail = tip.storeEmail ||
            tip.recipient?.storeEmail;
        if (isLikelyEmail(storeEmail))
            toSet.add(storeEmail.trim());
    }
    // b) 通知用メール配列
    const notify = tenSnap.get("notificationEmails");
    if (Array.isArray(notify)) {
        for (const e of notify)
            if (isLikelyEmail(e))
                toSet.add(e.trim());
    }
    // c) ★ 店舗管理者（tenant ドキュメントの members 配列 = UID 配列）→ users/{uid}.email を収集
    await addEmailsFromTenantMembersArray({
        db,
        toSet,
        tenantSnap: tenSnap,
    });
    // d) フォールバック
    if (toSet.size === 0) {
        const fallback = tip.employeeEmail ||
            tip.recipient?.employeeEmail ||
            tip.storeEmail;
        if (isLikelyEmail(fallback))
            toSet.add(fallback.trim());
    }
    const to = Array.from(toSet);
    if (to.length === 0) {
        console.warn("[tip mail] no recipient", { tenantId, tipId });
        return;
    }
    // -------- 付加情報（任意） --------
    const payerMessage = (typeof tip.payerMessage === "string" && tip.payerMessage.trim()) ||
        (typeof tip.senderMessage === "string" && tip.senderMessage.trim()) ||
        "";
    const createdAt = tip.createdAt?.toDate?.() ||
        (tip.createdAt instanceof Date ? tip.createdAt : undefined) ||
        new Date();
    const subject = `【おめでとう】チップが贈られてきました：${money(grossAmount)}`;
    const CONTACT_EMAIL = "56@zotman.jp";
    // テキスト版（ご指定どおり）
    const text = [
        `受取先：${displayName}`,
        `日時：${createdAt.toLocaleString("ja-JP")}`,
        ``,
        `■受領金額（内訳）`,
        `・チップ：${money(grossAmount)}`,
        `・Stripe手数料：${money(stripeFee)}`,
        `・プラットフォーム手数料：${money(platformFee)}`,
        `・店舗が差し引く金額：${money(storeDeduct)}`,
        ``,
        payerMessage ? `◾️送金者からのメッセージ\n${payerMessage}` : "",
        ``,
        `◾️管理者専用ページ`,
        `詳細は以下のリンクからログインして、明細の詳細をご確認ください。`,
        APP_BASE || "(アプリURL未設定)",
        ``,
        `---------------------------------`,
        `本メールがご自身宛でない場合、他の方が誤って同じメールアドレスを登録したものと考えられます。`,
        `配信停止のお手続きをさせていただきますので、件名に「宛先間違え」と本文に詳細をご記入の上、下記のお問い合わせメールにまでご連絡お願いします。`,
        `---------------------------------`,
        `◾️お問い合わせ`,
        `チップリ運営窓口`,
        CONTACT_EMAIL,
    ].filter(Boolean).join("\n");
    // HTML版（見出し・内容はテキスト版と一致）
    const html = `
<div style="font-family: system-ui, -apple-system, Segoe UI, Roboto, Helvetica, Arial; line-height:1.9; color:#111">
  <p style="margin:0 0 6px">受取先：<strong>${escapeHtml(displayName)}</strong></p>
  <p style="margin:0 0 16px">日時：${escapeHtml(createdAt.toLocaleString("ja-JP"))}</p>

  <h3 style="margin:0 0 6px">■受領金額（内訳）</h3>
  <ul style="margin:0 0 12px; padding-left:18px">
    <li>チップ：<strong>${escapeHtml(money(grossAmount))}</strong></li>
    <li>Stripe手数料：${escapeHtml(money(stripeFee))}</li>
    <li>プラットフォーム手数料：${escapeHtml(money(platformFee))}</li>
    <li>店舗が差し引く金額：${escapeHtml(money(storeDeduct))}</li>
  </ul>

  ${payerMessage ? `
  <h3 style="margin:16px 0 6px">◾️送金者からのメッセージ</h3>
  <p style="white-space:pre-wrap; margin:0 0 16px">${escapeHtml(payerMessage)}</p>
  ` : ""}

  <h3 style="margin:16px 0 6px">◾️管理者専用ページ</h3>
  <p style="margin:0 0 6px">詳細は以下のリンクからログインして、明細の詳細をご確認ください。</p>
  <p style="margin:0 0 16px">
    ${APP_BASE
        ? `<a href="${escapeHtml(APP_BASE)}" target="_blank" rel="noopener">${escapeHtml(APP_BASE)}</a>`
        : `<em>(アプリURL未設定)</em>`}
  </p>

  <p style="margin:12px 0 0">---------------------------------</p>
  <p style="margin:6px 0 0">
    本メールがご自身宛でない場合、他の方が誤って同じメールアドレスを登録したものと考えられます。<br />
    配信停止のお手続きをさせていただきますので、件名に「宛先間違え」と本文に詳細をご記入の上、下記のお問い合わせメールにまでご連絡お願いします。
  </p>
  <p style="margin:0 0 12px">---------------------------------</p>

  <p style="margin:0">
    ◾️お問い合わせ<br />
    チップリ運営窓口<br />
    <a href="mailto:${escapeHtml(CONTACT_EMAIL)}">${escapeHtml(CONTACT_EMAIL)}</a>
  </p>
</div>
`.trim();
    // -------- Resend 送信 --------
    const { Resend } = await Promise.resolve().then(() => __importStar(require("resend")));
    const resend = new Resend(resendApiKey);
    await resend.emails.send({
        from: "TIPRI チップリ <sendtip_app@appfromkomeda.jp>",
        to,
        subject,
        text,
        html,
    });
    // -------- 送信記録 --------
    await tipRef.set({
        notification: {
            emailedAt: admin.firestore.FieldValue.serverTimestamp(),
            to,
            subject,
            summary: {
                currency,
                gross: grossAmount,
                stripeFee,
                platformFee,
                storeDeduct,
            },
        },
    }, { merge: true });
}
/* ========= ヘルパー ========= */
function isLikelyEmail(x) {
    return typeof x === "string" && x.includes("@") && !/\s/.test(x);
}
async function addEmailsFromTenantMembersArray(params) {
    const { db, toSet, tenantSnap } = params;
    // tenant ドキュメントの members (UID配列)
    const members = tenantSnap.get("members");
    if (!Array.isArray(members) || members.length === 0)
        return;
    // UID を正規化 & 重複排除
    const uids = Array.from(new Set(members
        .map((v) => (typeof v === "string" ? v.trim() : ""))
        .filter((v) => v.length > 0)));
    if (uids.length === 0)
        return;
    const usersCol = db.collection("users");
    const idField = admin.firestore.FieldPath.documentId();
    // 'in' 条件の 10 件制限に合わせて分割
    for (let i = 0; i < uids.length; i += 10) {
        const batch = uids.slice(i, i + 10);
        try {
            const qs = await usersCol.where(idField, "in", batch).get();
            for (const doc of qs.docs) {
                const em = doc.get("email") ?? undefined;
                if (isLikelyEmail(em))
                    toSet.add(em.trim());
            }
        }
        catch {
            // フォールバック：個別 get()
            await Promise.all(batch.map(async (u) => {
                try {
                    const s = await usersCol.doc(u).get();
                    const em = s.get("email") ?? undefined;
                    if (isLikelyEmail(em))
                        toSet.add(em.trim());
                }
                catch { }
            }));
        }
    }
}
function yen(n) {
    const v = typeof n === "number" ? n : 0;
    return `¥${Number(v).toLocaleString("ja-JP")}`;
}
function tsFromSec(sec) {
    if (!sec && sec !== 0)
        return null;
    return admin.firestore.Timestamp.fromMillis(sec * 1000);
}
function fmtDate(d) {
    try {
        const date = d instanceof admin.firestore.Timestamp ? d.toDate() :
            d instanceof Date ? d : undefined;
        return date ? date.toLocaleString("ja-JP") : "-";
    }
    catch {
        return "-";
    }
}
async function sendInvoiceNotificationByCustomerId(customerId, inv, resendApiKey) {
    // 1) mapping を最初に参照
    const mapSnap = await db.collection("uidByCustomerId").doc(customerId).get();
    let map = (mapSnap.exists ? mapSnap.data() : {}) || {};
    let uid = typeof map.uid === "string" ? map.uid : undefined;
    let tenantId = typeof map.tenantId === "string" ? map.tenantId : undefined;
    const mappedEmail = typeof map.email === "string" ? map.email : undefined;
    // Fallback: tenantIndex 全走査（互換のため。将来は不要化可）
    if (!uid || !tenantId) {
        const idxSnap = await db.collection("tenantIndex").get();
        for (const d of idxSnap.docs) {
            const data = d.data() || {};
            if (data.subscription?.stripeCustomerId === customerId) {
                uid = data.uid;
                tenantId = data.tenantId;
                break;
            }
        }
    }
    if (!uid || !tenantId) {
        console.warn("[invoice mail] mapping not found for customerId:", customerId);
        return;
    }
    // 2) 店舗名の解決（優先: tenant → 次: tenantIndex）
    let tenantName;
    try {
        const tenSnap = await db.collection(uid).doc(tenantId).get();
        tenantName = tenSnap.get("name") ||
            tenSnap.get("tenantName") ||
            undefined;
    }
    catch { }
    if (!tenantName) {
        try {
            const idx = await db.collection("tenantIndex").doc(tenantId).get();
            tenantName = idx.get("name") ||
                idx.get("tenantName") ||
                undefined;
        }
        catch { }
    }
    tenantName || (tenantName = "店舗");
    // 3) 宛先の収集（重複削除）
    const toSet = new Set();
    // (a) mapping の email
    if (mappedEmail && mappedEmail.includes("@"))
        toSet.add(mappedEmail);
    // (b) tenant.notificationEmails
    try {
        const tenSnap = await db.collection(uid).doc(tenantId).get();
        const notify = tenSnap.get("notificationEmails");
        if (Array.isArray(notify)) {
            for (const e of notify)
                if (typeof e === "string" && e.includes("@"))
                    toSet.add(e);
        }
    }
    catch { }
    // (c) members の admin/owner
    try {
        const memSnap = await db.collection(uid).doc(tenantId).collection("members").get();
        for (const m of memSnap.docs) {
            const md = m.data() || {};
            const role = String(md.role ?? "admin").toLowerCase();
            if (role === "admin" || role === "owner") {
                const em = md.email;
                if (em && em.includes("@"))
                    toSet.add(em);
            }
        }
    }
    catch { }
    // 最低1件必要。なければ大人しく return（ログだけ）
    const recipients = Array.from(toSet);
    if (recipients.length === 0) {
        console.warn("[invoice mail] no recipients", { customerId, uid, tenantId, invoiceId: inv.id });
        return;
    }
    // 4) 表示用値の整形
    const currency = (inv.currency ?? "jpy").toUpperCase();
    const amountDue = inv.amount_due ?? null;
    const amountPaid = inv.amount_paid ?? null;
    const isJPY = currency === "JPY";
    const moneyDue = isJPY ? yen(amountDue) : `${amountDue ?? 0} ${currency}`;
    const moneyPaid = isJPY ? yen(amountPaid) : `${amountPaid ?? 0} ${currency}`;
    const created = tsFromSec(inv.created);
    const line0 = inv.lines?.data?.[0]?.period;
    const periodStart = tsFromSec(line0?.start ?? inv.created);
    const periodEnd = tsFromSec(line0?.end ?? inv.created);
    const nextAttempt = tsFromSec(inv.next_payment_attempt);
    const status = inv.status?.toUpperCase() || "UNKNOWN";
    const succeeded = inv.paid === true && status === "PAID";
    const subject = succeeded
        ? `【請求成功】${tenantName} のインボイス #${inv.number ?? inv.id}`
        : `【請求失敗】${tenantName} のインボイス #${inv.number ?? inv.id}`;
    const CONTACT_EMAIL = "56@zotman.jp";
    // テキスト版
    const lines = [
        `■請求情報`,
        `店舗名: ${tenantName}`,
        `インボイス: ${inv.number ?? inv.id}`,
        `ステータス: ${status}`,
        `金額（請求）: ${moneyDue}`,
        `金額（入金）: ${moneyPaid}`,
        `作成日時: ${fmtDate(created)}`,
        `対象期間: ${fmtDate(periodStart)} 〜 ${fmtDate(periodEnd)}`,
        inv.hosted_invoice_url ? `確認URL: ${inv.hosted_invoice_url}` : "",
        inv.invoice_pdf ? `PDF: ${inv.invoice_pdf}` : "",
        !succeeded && nextAttempt ? `次回再試行予定: ${fmtDate(nextAttempt)}` : "",
        "",
        "---------------------------------",
        "本メールがご自身宛でない場合、他の方が誤って同じメールアドレスを登録したものと考えられます。",
        "配信停止のお手続きをさせていただきますので、件名に「宛先間違え」と本文に詳細をご記入の上、下記のお問い合わせメールにまでご連絡お願いします。",
        "---------------------------------",
        "■お問い合わせ",
        "チップリ運営窓口",
        CONTACT_EMAIL,
    ].filter(Boolean);
    const text = lines.join("\n");
    // HTML版
    const html = `
<div style="font-family: system-ui, -apple-system, Segoe UI, Roboto, Helvetica, Arial; line-height:1.7; color:#111">
  <h2 style="margin:0 0 12px">${escapeHtml(subject)}</h2>

  <h3 style="margin:12px 0 6px">■請求情報</h3>
  <p style="margin:0 0 6px">店舗名：<strong>${escapeHtml(tenantName)}</strong></p>
  <p style="margin:0 0 6px">インボイス：<strong>${escapeHtml(inv.number ?? inv.id)}</strong></p>
  <p style="margin:0 0 6px">ステータス：<strong>${escapeHtml(status)}</strong></p>
  <p style="margin:0 0 6px">金額（請求）：<strong>${escapeHtml(moneyDue)}</strong></p>
  <p style="margin:0 0 6px">金額（入金）：<strong>${escapeHtml(moneyPaid)}</strong></p>
  <p style="margin:0 0 6px">作成日時：${escapeHtml(fmtDate(created))}</p>
  <p style="margin:0 0 6px">対象期間：${escapeHtml(fmtDate(periodStart))} 〜 ${escapeHtml(fmtDate(periodEnd))}</p>
  ${inv.hosted_invoice_url ? `<p style="margin:0 0 6px">確認URL：<a href="${escapeHtml(inv.hosted_invoice_url)}">${escapeHtml(inv.hosted_invoice_url)}</a></p>` : ""}
  ${inv.invoice_pdf ? `<p style="margin:0 0 6px">PDF：<a href="${escapeHtml(inv.invoice_pdf)}">${escapeHtml(inv.invoice_pdf)}</a></p>` : ""}
  ${!succeeded && nextAttempt ? `<p style="margin:0 0 6px">次回再試行予定：${escapeHtml(fmtDate(nextAttempt))}</p>` : ""}

  <hr style="border:none; border-top:1px solid #ddd; margin:16px 0" />

  <p style="margin:0 0 6px">
    本メールがご自身宛でない場合、他の方が誤って同じメールアドレスを登録したものと考えられます。<br />
    配信停止のお手続きをさせていただきますので、件名に「宛先間違え」と本文に詳細をご記入の上、下記のお問い合わせメールにまでご連絡お願いします。
  </p>

  <h3 style="margin:16px 0 6px">■お問い合わせ</h3>
  <p style="margin:0">
    チップリ運営窓口<br />
    <a href="mailto:${escapeHtml(CONTACT_EMAIL)}">${escapeHtml(CONTACT_EMAIL)}</a>
  </p>
</div>
`.trim();
    // 5) Resend で送信
    const { Resend } = await Promise.resolve().then(() => __importStar(require("resend")));
    const resend = new Resend(resendApiKey);
    await resend.emails.send({
        from: "TIPRI チップリ",
        to: recipients,
        subject,
        text,
        html,
    });
    // 任意: 送信記録を invoice サブコレクションに残す（オプション）
    try {
        await db.collection(uid).doc(tenantId).collection("invoices").doc(inv.id).set({
            _mail: {
                sentAt: admin.firestore.FieldValue.serverTimestamp(),
                to: recipients,
                subject,
            },
        }, { merge: true });
    }
    catch { }
}
/* ===================== ここまで支払 ===================== */
/* ===================== Stripe Webhook ===================== */
exports.stripeWebhook = functions
    .region("us-central1")
    .runWith({
    secrets: [
        "STRIPE_SECRET_KEY",
        "STRIPE_WEBHOOK_SECRET",
        "STRIPE_CONNECT_WEBHOOK_SECRET",
        "FRONTEND_BASE_URL",
        "STRIPE_PAYMENT_WEBHOOK_SECRET",
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
    // ===== 安全変換ヘルパ =====
    const toMillis = (sec) => {
        if (typeof sec === "number" && Number.isFinite(sec))
            return Math.trunc(sec * 1000);
        if (typeof sec === "string" && sec !== "") {
            const n = Number(sec);
            if (Number.isFinite(n))
                return Math.trunc(n * 1000);
        }
        return null;
    };
    const tsFromSec = (sec) => {
        const ms = toMillis(sec);
        return ms !== null ? admin.firestore.Timestamp.fromMillis(ms) : null;
    };
    const nowTs = () => admin.firestore.Timestamp.now();
    const putIf = (v, obj) => v !== null && v !== undefined ? obj : {};
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
    const requestOptions = event.account
        ? { stripeAccount: event.account }
        : undefined;
    const type = event.type;
    const docRef = db.collection("webhookEvents").doc(event.id);
    await docRef.set({
        type,
        receivedAt: admin.firestore.FieldValue.serverTimestamp(),
        handled: false,
    });
    // ★ 両方へ保存する小ヘルパ（{uid}/{tenantId} と tenantIndex）
    async function writeIndexAndOwner(uid, tenantId, patch) {
        await Promise.all([
            db.collection(uid).doc(tenantId).set(patch, { merge: true }),
            db.collection("tenantIndex").doc(tenantId).set({ ...patch, uid, tenantId }, { merge: true }),
        ]);
    }
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
                        const planSnap = await db.collection("billingPlans").doc(String(plan)).get();
                        feePercent = planSnap.exists
                            ? planSnap.data()?.feePercent
                            : undefined;
                    }
                    // uid の確定
                    let uid = uidMeta;
                    if (!uid) {
                        const tRefIdx = await tenantRefByIndex(tenantId);
                        uid = tRefIdx.parent.id;
                    }
                    const periodEndTs = tsFromSec(sub.current_period_end);
                    // ★ ここでは owner側のみ（下の subscription.updated でも反映されます）
                    await tenantRefByUid(uid, tenantId).set({
                        subscription: {
                            plan,
                            status: sub.status,
                            stripeCustomerId: customerId,
                            stripeSubscriptionId: sub.id,
                            ...putIf(periodEndTs, { currentPeriodEnd: periodEndTs, nextPaymentAt: periodEndTs }),
                            overdue: sub.status === "past_due" || sub.status === "unpaid", // ★追加
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
                        billing: {
                            initialFee: {
                                status: "paid"
                            }
                        }
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
            const createdAtTs = tsFromSec(stripeCreatedSec) ?? nowTs();
            if (!tenantIdMeta) {
                console.error("checkout.session.completed: missing tenantId in metadata");
            }
            else {
                if (!uid) {
                    const tRefIdx = await tenantRefByIndex(tenantIdMeta);
                    uid = tRefIdx.parent.id;
                }
                const tRef = tenantRefByUid(uid, tenantIdMeta);
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
                    const eff = await pickEffectiveRule(tenantIdMeta, createdAtTs.toDate(), uid);
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
                        // 支払い詳細を取る：payment_method と latest_charge を展開
                        const pi = await stripe.paymentIntents.retrieve(payIntentId, {
                            expand: [
                                "payment_method",
                                "latest_charge",
                                "latest_charge.balance_transaction",
                            ],
                        }, requestOptions // ← Connect対応
                        );
                        const latestCharge = (typeof pi.latest_charge === "object"
                            ? pi.latest_charge
                            : null) || null;
                        // ====== Stripe手数料など（既存ロジック） ======
                        const bt = latestCharge?.balance_transaction;
                        const stripeFee = bt?.fee ?? 0;
                        const stripeFeeCurrency = bt?.currency?.toUpperCase() ?? (session.currency ?? "jpy").toUpperCase();
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
                        // ====== 決済手段・カード要約の抽出 ======
                        let pm = null;
                        if (pi.payment_method && typeof pi.payment_method !== "string") {
                            pm = pi.payment_method;
                        }
                        else if (typeof pi.payment_method === "string") {
                            try {
                                pm = await stripe.paymentMethods.retrieve(pi.payment_method, requestOptions);
                            }
                            catch {
                                pm = null;
                            }
                        }
                        const pmd = latestCharge?.payment_method_details;
                        const cardOnCharge = pmd?.type === "card" ? pmd.card : undefined;
                        const cardOnPM = pm?.type === "card" ? pm.card : undefined;
                        const paymentSummary = {
                            method: pmd?.type || pm?.type || pi.payment_method_types?.[0],
                            paymentIntentId: pi.id,
                            chargeId: latestCharge?.id ||
                                (typeof pi.latest_charge === "string" ? pi.latest_charge : null),
                            paymentMethodId: pm?.id || (typeof pi.payment_method === "string" ? pi.payment_method : null),
                            captureMethod: pi.capture_method,
                            created: tsFromSec(pi.created) ?? nowTs(),
                        };
                        if (paymentSummary.method === "card" || cardOnPM || cardOnCharge) {
                            paymentSummary.card = {
                                brand: (cardOnCharge?.brand || cardOnPM?.brand || "").toString().toUpperCase() || null,
                                last4: cardOnCharge?.last4 || cardOnPM?.last4 || null,
                                expMonth: cardOnPM?.exp_month ?? null,
                                expYear: cardOnPM?.exp_year ?? null,
                                funding: cardOnPM?.funding ?? null,
                                country: cardOnPM?.country ?? null,
                                network: cardOnCharge?.network || cardOnPM?.networks?.preferred || null,
                                wallet: cardOnCharge?.wallet?.type || null,
                                threeDSecure: cardOnCharge?.three_d_secure?.result ??
                                    pmd?.card?.three_d_secure?.result ??
                                    null,
                            };
                        }
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
                                toStore,
                                toStaff,
                            },
                            payment: paymentSummary,
                            feesComputedAt: admin.firestore.FieldValue.serverTimestamp(),
                        }, { merge: true });
                    }
                }
                catch (err) {
                    console.error("Failed to enrich tip with stripe fee/payment details:", err);
                }
            }
        }
        /* ========== 2) Checkout その他 ========== */
        if (type === "checkout.session.expired" ||
            type === "checkout.session.async_payment_failed") {
            const session = event.data.object;
            const tenantId = session.metadata?.tenantId;
            if (tenantId) {
                let uid = session.metadata?.uid;
                if (!uid) {
                    const tRefIdx = await tenantRefByIndex(tenantId);
                    uid = tRefIdx.parent.id;
                }
            }
        }
        /* ========== 3) 購読の作成/更新 ========== */
        if (type === "customer.subscription.created" ||
            type === "customer.subscription.updated") {
            const sub = event.data.object;
            let tenantId = sub.metadata?.tenantId;
            let uid = sub.metadata?.uid;
            const plan = sub.metadata?.plan;
            if (!tenantId) {
                console.error("[sub.created/updated] missing tenantId in subscription.metadata", {
                    subId: sub.id,
                });
                await docRef.set({ handled: true }, { merge: true });
                res.sendStatus(200);
                return;
            }
            if (!uid) {
                const tRefIdx = await tenantRefByIndex(tenantId);
                uid = tRefIdx.parent.id;
            }
            const isTrialing = sub.status === "trialing";
            const trialStartTs = tsFromSec(sub.trial_start);
            const trialEndTs = tsFromSec(sub.trial_end);
            const periodEndTs = tsFromSec(sub.current_period_end);
            let feePercent;
            if (plan) {
                const planSnap = await db.collection("billingPlans").doc(String(plan)).get();
                feePercent = planSnap.exists
                    ? planSnap.data()?.feePercent
                    : undefined;
            }
            // ★ nextPaymentAt と overdue を追加し、両ドキュメントに反映
            const subPatch = {
                subscription: {
                    plan,
                    status: sub.status,
                    stripeCustomerId: sub.customer ?? undefined,
                    stripeSubscriptionId: sub.id,
                    ...putIf(periodEndTs, { currentPeriodEnd: periodEndTs, nextPaymentAt: periodEndTs }),
                    trial: {
                        status: isTrialing ? "trialing" : "none",
                        ...putIf(trialStartTs, { trialStart: trialStartTs }),
                        ...putIf(trialEndTs, { trialEnd: trialEndTs }),
                    },
                    overdue: sub.status === "past_due" || sub.status === "unpaid", // ★追加
                    ...(typeof feePercent === "number" ? { feePercent } : {}),
                    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                },
            };
            await writeIndexAndOwner(uid, tenantId, subPatch);
            // トライアル終了直後に再トライアル防止フラグを付与
            try {
                if (sub.status === "active" && typeof sub.trial_end === "number" && sub.trial_end * 1000 <= Date.now()) {
                    await stripe.customers.update(sub.customer, {
                        metadata: { zotman_trial_used: "true" },
                    });
                }
            }
            catch (e) {
                console.warn("Failed to set zotman_trial_used on customer:", e);
            }
            await docRef.set({ handled: true }, { merge: true });
            res.sendStatus(200);
            return;
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
                const periodEndTs = tsFromSec(sub.current_period_end);
                const patch = {
                    subscription: {
                        status: "nonactive", // ★ ここを 'canceled' ではなく nonactive に正規化
                        endedReason: "canceled", // 理由は別フィールドに保持
                        endedAt: admin.firestore.FieldValue.serverTimestamp(),
                        stripeSubscriptionId: sub.id,
                        ...putIf(periodEndTs, { currentPeriodEnd: periodEndTs, nextPaymentAt: periodEndTs }),
                        overdue: false,
                        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                    },
                };
                await writeIndexAndOwner(uid, tenantId, patch);
            }
        }
        /* ========== 4) 請求書（支払成功/失敗） ========== */
        if (type === "invoice.payment_succeeded" || type === "invoice.payment_failed") {
            const inv = event.data.object;
            const customerId = inv.customer;
            // トライアル明け最初の課金を検出 → Customerにフラグ
            try {
                if (type === "invoice.payment_succeeded" &&
                    inv.paid &&
                    inv.billing_reason === "subscription_cycle" &&
                    inv.subscription) {
                    const sub = await stripe.subscriptions.retrieve(inv.subscription);
                    if (typeof sub.trial_end === "number" && sub.trial_end * 1000 <= Date.now()) {
                        await stripe.customers.update(customerId, {
                            metadata: { zotman_trial_used: "true" },
                        });
                    }
                }
            }
            catch (e) {
                console.warn("Failed to mark zotman_trial_used on invoice.payment_succeeded:", e);
            }
            // 既存のテナント検索・invoices 保存
            const idxSnap = await db.collection("tenantIndex").get();
            for (const d of idxSnap.docs) {
                const data = d.data();
                const uid = data.uid;
                const tenantId = data.tenantId;
                const t = await db.collection(uid).doc(tenantId).get();
                if (t.exists && t.get("subscription.stripeCustomerId") === customerId) {
                    const createdTs = tsFromSec(inv.created) ?? nowTs();
                    const line0 = inv.lines?.data?.[0]?.period;
                    const psTs = tsFromSec(line0?.start ?? inv.created) ?? createdTs;
                    const peTs = tsFromSec(line0?.end ?? inv.created) ?? createdTs;
                    // invoices コレクションは従来どおり保存
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
                        created: createdTs,
                        period_start: psTs,
                        period_end: peTs,
                        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                    }, { merge: true });
                    // ★ 未払い/解消 と 次回再試行（失敗時）・直近請求サマリを保存（owner & index）
                    const nextAttemptTs = tsFromSec(inv.next_payment_attempt);
                    const subPatch = type === "invoice.payment_failed"
                        ? {
                            subscription: {
                                overdue: true,
                                latestInvoice: {
                                    id: inv.id,
                                    status: inv.status,
                                    amountDue: inv.amount_due ?? null,
                                    hostedInvoiceUrl: inv.hosted_invoice_url ?? null,
                                },
                                ...putIf(nextAttemptTs, { nextPaymentAttemptAt: nextAttemptTs }),
                                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                            },
                        }
                        : {
                            subscription: {
                                overdue: false,
                                latestInvoice: {
                                    id: inv.id,
                                    status: inv.status,
                                    amountPaid: inv.amount_paid ?? null,
                                    hostedInvoiceUrl: inv.hosted_invoice_url ?? null,
                                },
                                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                            },
                        };
                    await writeIndexAndOwner(uid, tenantId, subPatch);
                    break;
                }
            }
            try {
                await sendInvoiceNotificationByCustomerId(customerId, inv, exports.RESEND_API_KEY.value());
            }
            catch (e) {
                console.warn("[invoice mail] failed to send:", e);
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
                // インデックスにも反映
                const tSnap = await tRef.get();
                const tenantId = tSnap.id;
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
                // インデックスにも反映
                await db.collection("tenantIndex").doc(tenantId).set({
                    billing: {
                        initialFee: {
                            status: "paid",
                            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                        },
                    },
                }, { merge: true });
            }
        }
        /* ========== トライアル終了予告（通知用に保存） ========== */
        if (type === "customer.subscription.trial_will_end") {
            const sub = event.data.object;
            const tenantId = sub.metadata?.tenantId;
            let uid = sub.metadata?.uid;
            if (tenantId) {
                if (!uid) {
                    const tRefIdx = await tenantRefByIndex(tenantId);
                    uid = tRefIdx.parent.id;
                }
                const trialEndTs = tsFromSec(sub.trial_end);
                await db
                    .collection(uid)
                    .doc(tenantId)
                    .collection("alerts")
                    .add({
                    type: "trial_will_end",
                    stripeSubscriptionId: sub.id,
                    ...(trialEndTs ? { trialEnd: trialEndTs } : {}),
                    createdAt: admin.firestore.FieldValue.serverTimestamp(),
                    read: false,
                });
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
// Secrets
const STRIPE_SECRET_KEY = (0, params_1.defineSecret)("STRIPE_SECRET_KEY");
const FRONTEND_BASE_URL = (0, params_1.defineSecret)("FRONTEND_BASE_URL");
exports.inviteTenantAdmin = (0, https_1.onCall)({
    region: "us-central1",
    memory: "256MiB",
    secrets: [exports.RESEND_API_KEY],
}, async (req) => {
    const uid = req.auth?.uid;
    if (!uid)
        throw new https_1.HttpsError("unauthenticated", "Sign in");
    const tenantId = (req.data?.tenantId || "").toString();
    const emailRaw = (req.data?.email || "").toString();
    const emailLower = emailRaw.trim().toLowerCase();
    if (!tenantId || !emailLower.includes("@")) {
        throw new https_1.HttpsError("invalid-argument", "bad tenantId/email");
    }
    // 権限チェック
    await assertTenantAdmin(tenantId, uid);
    // ===== 追加: 店舗名と招待者名を取得 =====
    // 店舗名（name / tenantName のどちらかが入っている想定）
    const tenSnap = await db.collection(uid).doc(tenantId).get();
    const tenantName = tenSnap.get("name") ||
        tenSnap.get("tenantName") ||
        "店舗";
    // 招待者表示名（なければメール、どちらも無ければUID）
    let inviterDisplay = req.auth?.token?.name ||
        req.auth?.token?.email ||
        "";
    if (!inviterDisplay) {
        try {
            const inviterUser = await admin.auth().getUser(uid);
            inviterDisplay =
                inviterUser.displayName || inviterUser.email || `UID:${uid}`;
        }
        catch {
            inviterDisplay = `UID:${uid}`;
        }
    }
    // すでにメンバーなら終了（既存処理）
    const userByEmail = await admin.auth().getUserByEmail(emailLower).catch(() => null);
    if (userByEmail) {
        const memberRef = db.doc(`${uid}/${tenantId}/members/${userByEmail.uid}`);
        const mem = await memberRef.get();
        if (mem.exists)
            return { ok: true, alreadyMember: true };
    }
    // 招待トークン作成（既存処理）
    const token = crypto.randomBytes(32).toString("hex");
    const tokenHash = sha256(token);
    const expiresAt = admin.firestore.Timestamp.fromDate(new Date(Date.now() + 1000 * 60 * 60 * 24 * 7));
    const invitesCol = db.collection(`${uid}/${tenantId}/invites`);
    const existing = await invitesCol
        .where("emailLower", "==", emailLower)
        .where("status", "==", "pending")
        .limit(1)
        .get();
    let inviteRef;
    if (existing.empty) {
        inviteRef = invitesCol.doc();
        await inviteRef.set({
            emailLower,
            tokenHash,
            status: "pending",
            invitedBy: {
                uid,
                email: req.auth?.token?.email || null,
                name: inviterDisplay, // ←保存しておくと後で見れて便利
            },
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
            expiresAt,
            tenantName, // ←参考用に保存（任意）
        });
    }
    else {
        inviteRef = existing.docs[0].ref;
        await inviteRef.update({
            tokenHash,
            expiresAt,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            tenantName, // ←上書き（任意）
        });
    }
    // 送信
    const { Resend } = await Promise.resolve().then(() => __importStar(require("resend")));
    const resend = new Resend(exports.RESEND_API_KEY.value());
    // 受諾URLは既存のまま
    const acceptUrl = `${APP_ORIGIN}/#/admin-invite?tenantId=${encodeURIComponent(tenantId)}&token=${encodeURIComponent(token)}`;
    // ▼ 件名・本文を指定の文面に差し替え
    const subject = "【TIPRI チップリ】店舗管理者として招待されました。内容を確認をお願いいたします。";
    // テキスト本文（そのままコピペで出るように改行・記号も固定）
    const text = [
        "【TIPRI チップリ】店舗管理者として招待されました。内容を確認をお願いいたします。",
        "",
        `■店舗名：${tenantName}`,
        "",
        `■招待者：${inviterDisplay}`,
        "",
        "■7日以内に以下のリンクから承認してください。",
        acceptUrl,
        "",
        "--------------------------------",
        "本メールがご自身宛でない場合、他の方が誤って同じメールアドレスを登録したものと考えられます。",
        "配信停止のお手続きをさせていただきますので、件名に「宛先間違え」と本文に詳細をご記入の上、下記のお問い合わせメールにまでご連絡お願いします。",
        "---------------------------------",
        "■お問い合わせ",
        "チップリ運営窓口",
        "56@zotman.jp",
    ].join("\n");
    // HTML本文（見た目は同等。装飾は最小限、本文はご指定の表現を忠実に）
    const html = `
<div style="font-family: system-ui, -apple-system, Segoe UI, Roboto, Helvetica, Arial; line-height:1.8; color:#111">
  <p style="margin:0 0 10px;">【TIPRI チップリ】店舗管理者として招待されました。内容を確認をお願いいたします。</p>

  <p style="margin:14px 0 0;"><strong>■店舗名：</strong>${escapeHtml(tenantName)}</p>

  <p style="margin:10px 0 0;"><strong>■招待者：</strong>${escapeHtml(inviterDisplay)}</p>

  <p style="margin:10px 0 4px;"><strong>■7日以内に以下のリンクから承認してください。</strong></p>
  <p style="margin:0;">
    <a href="${escapeHtml(acceptUrl)}" target="_blank" rel="noopener">${escapeHtml(acceptUrl)}</a>
  </p>

  <p style="margin:18px 0 0;">--------------------------------</p>
  <p style="margin:6px 0 0;">
    本メールがご自身宛でない場合、他の方が誤って同じメールアドレスを登録したものと考えられます。<br>
    配信停止のお手続きをさせていただきますので、件名に「宛先間違え」と本文に詳細をご記入の上、下記のお問い合わせメールにまでご連絡お願いします。
  </p>
  <p style="margin:0 0 10px;">---------------------------------</p>

  <p style="margin:10px 0 0;"><strong>■お問い合わせ</strong><br>
  チップリ運営窓口<br>
  <a href="mailto:56@zotman.jp">56@zotman.jp</a></p>
</div>
`.trim();
    // Resend送信は既存どおり
    await resend.emails.send({
        from: "TIPRI チップリ",
        to: [emailLower],
        subject,
        text,
        html,
    });
    await inviteRef.set({ emailedAt: admin.firestore.FieldValue.serverTimestamp() }, { merge: true });
    return { ok: true };
});
exports.acceptTenantAdminInvite = functions.https.onCall(async (data, context) => {
    const authedUid = context.auth?.uid;
    const email = (context.auth?.token?.email || "").toLowerCase();
    if (!authedUid || !email)
        throw new functions.https.HttpsError("unauthenticated", "Sign in");
    const tenantId = (data?.tenantId || "").toString();
    const token = (data?.token || "").toString();
    if (!tenantId || !token) {
        throw new functions.https.HttpsError("invalid-argument", "tenantId/token required");
    }
    // ★ オーナー uid を tenantIndex から取得
    const idx = await db.collection("tenantIndex").doc(tenantId).get();
    if (!idx.exists)
        throw new functions.https.HttpsError("not-found", "tenantIndex not found");
    const ownerUid = idx.data().uid;
    const tokenHash = sha256(token);
    const q = await db
        .collection(`${ownerUid}/${tenantId}/invites`) // ★ ownerUid 配下
        .where("tokenHash", "==", tokenHash)
        .limit(1)
        .get();
    if (q.empty)
        throw new functions.https.HttpsError("not-found", "Invite not found");
    const inviteDoc = q.docs[0];
    const inv = inviteDoc.data();
    if (inv.status !== "pending") {
        throw new functions.https.HttpsError("failed-precondition", "Invite already processed");
    }
    if (inv.expiresAt?.toMillis?.() < Date.now()) {
        throw new functions.https.HttpsError("deadline-exceeded", "Invite expired");
    }
    if (inv.emailLower !== email) {
        throw new functions.https.HttpsError("permission-denied", "Invite email mismatch");
    }
    await db.runTransaction(async (tx) => {
        const memRef = db.doc(`${ownerUid}/${tenantId}/members/${authedUid}`);
        const tRef = db.doc(`${ownerUid}/${tenantId}`);
        // ★ 追加: 承認したユーザー側の "invited" ドキュメントに保存する参照
        const invitedRef = db.collection(authedUid).doc("invited");
        // members に追加
        tx.set(memRef, {
            role: "admin",
            email,
            displayName: context.auth?.token?.name || null,
            addedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
        // tenant ドキュメントに UID を積む
        tx.set(tRef, { memberUids: admin.firestore.FieldValue.arrayUnion(authedUid) }, { merge: true });
        // 招待を accepted に
        tx.update(inviteDoc.ref, {
            status: "accepted",
            acceptedAt: admin.firestore.FieldValue.serverTimestamp(),
            acceptedBy: { uid: authedUid, email },
        });
        // ★ 追加: 承認ユーザー側に { ownerUid, tenantId } を保存
        // 複数テナントに対応できるよう、tenants.<tenantId> に入れて merge
        tx.set(invitedRef, {
            tenants: {
                [tenantId]: {
                    ownerUid,
                    tenantId,
                    acceptedAt: admin.firestore.FieldValue.serverTimestamp(),
                },
            },
        }, { merge: true });
    });
    return { ok: true };
});
exports.cancelTenantAdminInvite = functions.https.onCall(async (data, context) => {
    const actorUid = context.auth?.uid;
    if (!actorUid)
        throw new functions.https.HttpsError("unauthenticated", "Sign in");
    const tenantId = (data?.tenantId || "").toString();
    const inviteId = (data?.inviteId || "").toString();
    if (!tenantId || !inviteId) {
        throw new functions.https.HttpsError("invalid-argument", "tenantId/inviteId required");
    }
    // ★ tenantIndex からオーナー uid を取得
    const idx = await db.collection("tenantIndex").doc(tenantId).get();
    if (!idx.exists)
        throw new functions.https.HttpsError("not-found", "tenantIndex not found");
    const ownerUid = idx.data().uid;
    // ★ 権限チェック：オーナー名前空間のテナントで、呼び出しユーザーが admin/owner か
    const tSnap = await db.collection(ownerUid).doc(tenantId).get();
    if (!tSnap.exists)
        throw new functions.https.HttpsError("not-found", "Tenant not found");
    const members = (tSnap.data()?.members ?? []);
    const isAdmin = Array.isArray(members) &&
        members.some((m) => {
            if (typeof m === "string")
                return m === actorUid;
            if (m && typeof m === "object") {
                const mid = m.uid ?? m.id ?? m.userId;
                const role = String(m.role ?? "admin").toLowerCase();
                return mid === actorUid && (role === "admin" || role === "owner");
            }
            return false;
        });
    if (!isAdmin) {
        throw new functions.https.HttpsError("permission-denied", "Not tenant admin");
    }
    // ★ 招待はオーナー uid 名前空間にある
    await db.doc(`${ownerUid}/${tenantId}/invites/${inviteId}`).update({
        status: "canceled",
        canceledAt: admin.firestore.FieldValue.serverTimestamp(),
        canceledBy: actorUid,
    });
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
    const TRIAL_DAYS = 90;
    const planDoc = await getPlanFromDb(plan);
    const purchaserEmail = email || context.auth?.token?.email;
    const customerId = await ensureCustomer(uid, tenantId, purchaserEmail, name);
    // 進行中購読があればポータルへ
    const subs = await stripe.subscriptions.list({ customer: customerId, status: "all", limit: 20 });
    const hasOngoing = subs.data.some((s) => ["active", "trialing", "past_due", "unpaid"].includes(s.status));
    if (hasOngoing) {
        const portal = await stripe.billingPortal.sessions.create({
            customer: customerId,
            return_url: `${APP_BASE}#/settings?tenant=${encodeURIComponent(tenantId)}`,
        });
        return { alreadySubscribed: true, portalUrl: portal.url };
    }
    const successUrl = `${APP_BASE}#/store?tenantId=${tenantId}&event=initial_fee_paid`;
    const cancelUrl = `${APP_BASE}#/store?tenantId=${tenantId}&event=initial_fee_canceled`;
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
exports.changeSubscriptionPlan = functions
    .region("us-central1")
    .runWith({ secrets: ["STRIPE_SECRET_KEY"] })
    .https.onCall(async (data, context) => {
    const uid = context.auth?.uid;
    if (!uid)
        throw new functions.https.HttpsError("unauthenticated", "Sign-in required");
    const { subscriptionId, newPlan } = (data || {});
    if (!subscriptionId || !newPlan) {
        throw new functions.https.HttpsError("invalid-argument", "subscriptionId and newPlan are required.");
    }
    const STRIPE_KEY = process.env.STRIPE_SECRET_KEY;
    const stripe = new stripe_1.default(STRIPE_KEY, { apiVersion: "2023-10-16" });
    // 新プランの Price を解決
    const newPlanDoc = await getPlanFromDb(newPlan);
    // 現在の購読取得
    const sub = (await stripe.subscriptions.retrieve(subscriptionId));
    const item = sub.items.data[0];
    // trial_end は number のときだけ渡す（undefined なら Stripe が自動維持）
    const trialEndParam = typeof sub.trial_end === "number" ? sub.trial_end : undefined;
    const updated = await stripe.subscriptions.update(subscriptionId, {
        items: [
            {
                id: item.id,
                price: newPlanDoc.stripePriceId,
                quantity: item.quantity ?? 1,
            },
        ],
        proration_behavior: "none",
        trial_end: trialEndParam, // ← 安全に
        trial_from_plan: false,
        metadata: { ...sub.metadata, plan: newPlan },
    });
    return { ok: true, subscription: updated.id };
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
    cors: ALLOWED_ORIGINS,
    secrets: ["STRIPE_SECRET_KEY", "FRONTEND_BASE_URL"],
}, async (req) => {
    if (!req.auth)
        throw new https_1.HttpsError("unauthenticated", "auth required");
    const uid = req.auth.uid;
    const tenantId = req.data?.tenantId;
    const form = (req.data?.account || {});
    if (!tenantId)
        throw new https_1.HttpsError("invalid-argument", "tenantId required");
    // テナント実体をオーナー配下から取得（オーナー=uid 前提）
    const tRef = tenantRefByUid(uid, tenantId);
    const tDoc = await tRef.get();
    if (!tDoc.exists)
        throw new https_1.HttpsError("not-found", "tenant not found");
    // メンバー権限チェック（members: string[] or memberUids: string[] どちらでも可）
    const data = tDoc.data() || {};
    const members = (data.members ?? data.memberUids ?? []);
    if (!Array.isArray(members) || !members.includes(uid)) {
        throw new https_1.HttpsError("permission-denied", "not a tenant member");
    }
    // 受け取る入金スケジュール（任意）
    const schIn = (req.data?.payoutSchedule || {});
    // Stripe クライアント
    const stripe = stripeClient();
    // 既存アカウントID
    let acctId = data.stripeAccountId;
    const country = form.country || "JP";
    // 入金スケジュールオブジェクトを構築（指定があるときのみ）
    const schedule = {};
    if (schIn.interval)
        schedule.interval = schIn.interval;
    if (schIn.interval === "weekly" && schIn.weeklyAnchor) {
        schedule.weekly_anchor = schIn.weeklyAnchor;
    }
    if (schIn.interval === "monthly" &&
        typeof schIn.monthlyAnchor === "number") {
        schedule.monthly_anchor = schIn.monthlyAnchor;
    }
    if (schIn.delayDays !== undefined) {
        schedule.delay_days = schIn.delayDays;
    }
    const hasSchedule = Object.keys(schedule).length > 0 &&
        typeof schedule.interval !== "undefined";
    // まだ Connect アカウントがない場合は作成（Custom）
    if (!acctId) {
        const created = await stripe.accounts.create({
            type: "custom",
            country,
            email: form.email,
            business_type: form.businessType || "individual",
            capabilities: {
                card_payments: { requested: true },
                transfers: { requested: true },
            },
            // 作成時点でスケジュールを入れたい場合
            settings: hasSchedule ? { payouts: { schedule } } : undefined,
        });
        acctId = created.id;
        await tRef.set({
            stripeAccountId: acctId,
            connect: {
                charges_enabled: created.charges_enabled,
                payouts_enabled: created.payouts_enabled,
            },
        }, { merge: true });
        // テナントインデックスにも反映
        await upsertTenantIndex(uid, tenantId, acctId);
    }
    // 更新パラメータを組み立て
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
    // 入金スケジュールの更新（指定があるときのみ）
    if (hasSchedule) {
        upd.settings = {
            ...(upd.settings || {}),
            payouts: {
                ...(upd.settings?.payouts || {}),
                schedule,
            },
        };
    }
    // Stripe アカウント更新
    const updated = await stripe.accounts.update(acctId, upd);
    // 追加提出が必要なら hosted onboarding へ
    const due = updated.requirements?.currently_due ?? [];
    const pastDue = updated.requirements?.past_due ?? [];
    const needsHosted = due.length > 0 || pastDue.length > 0;
    let onboardingUrl;
    if (needsHosted) {
        const BASE = process.env.FRONTEND_BASE_URL;
        // refresh/return は絶対URL必須
        const link = await stripe.accountLinks.create({
            account: acctId,
            type: "account_onboarding",
            refresh_url: `${BASE}#/store?tenantId=${encodeURIComponent(tenantId)}&event=initial_fee_canceled`,
            return_url: `${BASE}#/store?tenantId=${encodeURIComponent(tenantId)}&event=initial_fee_paid`,
        });
        onboardingUrl = link.url;
    }
    // Firestore へ最新状態を保存（現在の payoutSchedule も保持）
    await tRef.set({
        connect: {
            charges_enabled: updated.charges_enabled,
            payouts_enabled: updated.payouts_enabled,
            requirements: updated.requirements || null,
        },
        payoutSchedule: updated.settings?.payouts?.schedule ?? null,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });
    // インデックスの保守
    await upsertTenantIndex(uid, tenantId, acctId);
    return {
        accountId: acctId,
        chargesEnabled: updated.charges_enabled,
        payoutsEnabled: updated.payouts_enabled,
        due,
        onboardingUrl,
        payoutSchedule: updated.settings?.payouts?.schedule ?? null,
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
    const successUrl = `${APP_BASE}#/store?tenantId=${tenantId}&event=initial_fee_paid`;
    const cancelUrl = `${APP_BASE}#/store?tenantId=${tenantId}&event=initial_fee_canceled`;
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
exports.createCustomerPortalSession = (0, https_1.onCall)({
    secrets: [STRIPE_SECRET_KEY, FRONTEND_BASE_URL],
    // region/memory は setGlobalOptions で指定済み（ここに書いてもOK）
}, async (req) => {
    if (!req.auth)
        throw new https_1.HttpsError("unauthenticated", "auth required");
    const APP_BASE = FRONTEND_BASE_URL.value();
    const uid = req.auth.uid;
    const tenantId = req.data?.tenantId?.trim();
    if (!tenantId)
        throw new https_1.HttpsError("invalid-argument", "tenantId required");
    const email = req.auth.token.email ?? undefined;
    const name = req.auth.token.name ?? undefined;
    const customerId = await ensureCustomer(uid, tenantId, email, name);
    const stripe = new stripe_1.default(STRIPE_SECRET_KEY.value(), { apiVersion: "2023-10-16" });
    const returnUrl = `${APP_BASE}#/account?tenantId=${encodeURIComponent(tenantId)}`;
    const session = await stripe.billingPortal.sessions.create({
        customer: customerId,
        return_url: returnUrl,
    });
    return { url: session.url };
});
/**
 * 2) Stripe Connect アカウントリンク（口座確認/更新）
 *  - Express: login link
 *  - Custom : account_onboarding / account_update
 */
exports.createConnectAccountLink = (0, https_1.onCall)({
    secrets: [STRIPE_SECRET_KEY, FRONTEND_BASE_URL],
}, async (req) => {
    if (!req.auth)
        throw new https_1.HttpsError("unauthenticated", "auth required");
    const APP_BASE = FRONTEND_BASE_URL.value();
    const uid = req.auth.uid;
    const tenantId = req.data?.tenantId?.trim();
    if (!tenantId)
        throw new https_1.HttpsError("invalid-argument", "tenantId required");
    const tRef = db.collection(uid).doc(tenantId);
    const tSnap = await tRef.get();
    if (!tSnap.exists)
        throw new https_1.HttpsError("not-found", "tenant not found");
    const stripeAccountId = tSnap.data()?.stripeAccountId ?? undefined;
    if (!stripeAccountId)
        throw new https_1.HttpsError("failed-precondition", "Connect account not created");
    const stripe = new stripe_1.default(STRIPE_SECRET_KEY.value(), { apiVersion: "2023-10-16" });
    const acct = await stripe.accounts.retrieve(stripeAccountId);
    const returnUrl = `${APP_BASE}#/account?tenantId=${encodeURIComponent(tenantId)}`;
    const refreshUrl = returnUrl;
    if (acct.type === "express") {
        const link = await stripe.accounts.createLoginLink(stripeAccountId);
        return { url: link.url };
    }
    const due = acct.requirements?.currently_due ?? [];
    const pastDue = acct.requirements?.past_due ?? [];
    const needsOnboarding = (due.length + pastDue.length) > 0;
    const link = await stripe.accountLinks.create({
        account: stripeAccountId,
        type: needsOnboarding ? "account_onboarding" : "account_update",
        return_url: returnUrl,
        refresh_url: refreshUrl,
    });
    return { url: link.url };
});
