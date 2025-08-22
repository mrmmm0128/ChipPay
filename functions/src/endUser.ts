import * as functions from "firebase-functions";
import Stripe from "stripe";

import { admin } from "./admin";
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
    