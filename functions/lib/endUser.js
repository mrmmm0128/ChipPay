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
exports.createStoreTipSessionPublic = exports.createTipSessionPublic = void 0;
const functions = __importStar(require("firebase-functions"));
const admin = __importStar(require("firebase-admin"));
const stripe_1 = __importDefault(require("stripe"));
const dotenv = __importStar(require("dotenv"));
dotenv.config();
admin.initializeApp();
const db = admin.firestore();
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
/** 公開ページ（未ログイン）からのチップ用：Connect 宛先＋手数料対応 */
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
    // テナント状態
    const tRef = db.collection("tenants").doc(tenantId);
    const tDoc = await tRef.get();
    if (!tDoc.exists || tDoc.data().status !== "active") {
        throw new functions.https.HttpsError("failed-precondition", "Tenant suspended or not found");
    }
    // Stripe Connect 必須
    const acctId = tDoc.data()?.stripeAccountId;
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
    const employeeName = eDoc.data()?.name ?? "Staff";
    const FRONTEND_BASE_URL = requireEnv("FRONTEND_BASE_URL");
    const stripe = stripeClient();
    // 手数料（無ければ 0 として処理）
    const feeCfg = (tDoc.data()?.fee ?? {});
    const appFee = calcApplicationFee(amount, feeCfg);
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
                        unit_amount: amount, // JPY: 1円単位
                    },
                    quantity: 1,
                },
            ],
            success_url: `${FRONTEND_BASE_URL}/#/p?t=${tenantId}&thanks=true`,
            cancel_url: `${FRONTEND_BASE_URL}/#/p?t=${tenantId}&canceled=true`,
            metadata: {
                tenantId,
                employeeId,
                employeeName, // 追加
                tipDocId: tipRef.id, // 追加（WebhookでこのIDを優先して更新）
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
    }
    catch (err) {
        // 失敗時も pending のまま残る（必要なら削除/フラグ更新を検討）
        throw new functions.https.HttpsError("failed-precondition", err?.message || "Stripe error", { source: "stripe", code: err?.type || "stripe_error" });
    }
});
// 店舗向け：従業員IDなしでチップ用Checkoutを作成
exports.createStoreTipSessionPublic = functions.region("us-central1")
    .runWith({
    secrets: ["STRIPE_SECRET_KEY", "FRONTEND_BASE_URL"],
    memory: "256MB",
})
    .https.onCall(async (data, _ctx) => {
    const { tenantId, amount, memo = "Tip to store" } = data;
    // ====== 入力チェック ======
    if (!tenantId) {
        throw new functions.https.HttpsError("invalid-argument", "tenantId required");
    }
    if (!Number.isInteger(amount) ||
        (amount ?? 0) <= 0 ||
        amount > 1000000) {
        throw new functions.https.HttpsError("invalid-argument", "invalid amount");
    }
    // ====== テナント・Stripe接続チェック ======
    const tSnap = await db.collection("tenants").doc(tenantId).get();
    if (!tSnap.exists || tSnap.data().status !== "active") {
        throw new functions.https.HttpsError("failed-precondition", "Tenant suspended or not found");
    }
    const acctId = tSnap.data()?.stripeAccountId;
    if (!acctId) {
        throw new functions.https.HttpsError("failed-precondition", "Store not connected to Stripe");
    }
    const chargesEnabled = !!tSnap.data()?.connect?.charges_enabled;
    if (!chargesEnabled) {
        throw new functions.https.HttpsError("failed-precondition", "Store Stripe account is not ready (charges_disabled)");
    }
    // ====== Stripe Checkout セッション ======
    const stripe = stripeClient();
    const frontendBase = requireEnv("FRONTEND_BASE_URL");
    const currency = "jpy"; // JPY想定（最小単位で金額を渡す）
    const unitAmount = amount;
    const storeName = tSnap.data()?.name ?? tenantId;
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
    await db.collection("paymentSessions").doc(session.id).set({
        tenantId,
        amount: unitAmount,
        currency: currency.toUpperCase(),
        status: "pending",
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });
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
