import * as functions from "firebase-functions";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { onDocumentWritten } from "firebase-functions/v2/firestore";
import { defineSecret } from "firebase-functions/params";
import * as admin from "firebase-admin";
import Stripe from "stripe";
import * as crypto from "crypto";
import * as bcrypt from "bcryptjs";
import * as logger from "firebase-functions/logger";


/* ===================== initialize ===================== */
if (!admin.apps.length) admin.initializeApp();
const db = admin.firestore();
const OWNER_EMAILS = new Set(["appfromkomeda@gmail.com"]); // 自分の運営アカウントに置換

/* ===================== Secrets / Const ===================== */
const RESEND_API_KEY = defineSecret("RESEND_API_KEY");
const STRIPE_SECRET_KEY = defineSecret("STRIPE_SECRET_KEY");
const FRONTEND_BASE_URL = defineSecret("FRONTEND_BASE_URL");
const APP_ORIGIN = "https://tipri.jp"
const ALLOWED_ORIGINS = [
  APP_ORIGIN,
  "https://tipri.pages.dev"
].filter(Boolean) as string[];


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


async function pickInitialFeeLinesAll(
  stripe: Stripe,
  inv: Stripe.Invoice,
  initialFeePriceId: string
): Promise<{ hits: Stripe.ApiList<Stripe.InvoiceLineItem>["data"]; amount: number }> {
  // Webhookのinv.linesがページング済みの可能性に対応して全件取る
  const all = await stripe.invoices.listLineItems(inv.id, {
    limit: 100,
    expand: ["data.price"],
  });

  const hits = all.data.filter((ln) => {
    const price = ln.price as Stripe.Price | undefined;
    return price && price.id === initialFeePriceId;
  });

  const amount = hits.reduce((sum, ln) => sum + (ln.amount ?? 0), 0);
  return { hits, amount };
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

// どこか共通 utils へ
function deriveConnectStatus(acct: Stripe.Account):
  "active" | "action_required" | "pending" | "disabled" {
  const r = acct.requirements;
  // 完全に有効
  if (acct.charges_enabled && acct.payouts_enabled) return "active";
  // 入力が必要（不足項目あり/期限切れ）
  if ((r!.past_due?.length ?? 0) > 0) return "action_required";
  if ((r!.currently_due?.length ?? 0) > 0) return "action_required";
  // 申請中（審査待ち）
  if ((r!.pending_verification?.length ?? 0) > 0) return "pending";
  // 申請完了しているが、まだ有効化されていない（審査中等）
  if (acct.details_submitted && !acct.payouts_enabled) return "pending";
  // Stripe が利用停止にしている等
  if (r!.disabled_reason) return "disabled";

  // どれにも当てはまらない場合は pending 扱い
  return "pending";
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

type TenantDoc = {
  customerId?: string; // ← 正とする
  subscription?: {
    stripeCustomerId?: string; // ← ミラー保存（削除しない）
    // ほかサブスクリプション項目があればここに追加
  };
};

function cleanId(v: unknown): string | undefined {
  return typeof v === "string" && v.trim() ? v.trim() : undefined;
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
  const tData = (tSnap.data() || {}) as TenantDoc;

  const rootId = cleanId(tData.customerId);
  const subId = cleanId(tData.subscription?.stripeCustomerId);

  // 1) root（正）にある → 返す＆subscription に同期
  if (rootId) {
    if (subId !== rootId) {
      await tenantRef.set(
        { subscription: { ...(tData.subscription || {}), stripeCustomerId: rootId } },
        { merge: true }
      );
    }
    await upsertTenantIndex(uid, tenantId);
    const cusIdRef = db.collection("uidByCustomerId").doc(rootId)
      await cusIdRef.set(
{
  uid: uid, tenantId: tenantId,  email: email
}, {merge: true}
      );
    return rootId;
  }

  // 2) root 無くて subscription にある → root へ移行保存して返す
  if (subId) {
    await tenantRef.set(
      {
        customerId: subId,
      },
      { merge: true }
    );
    await upsertTenantIndex(uid, tenantId);
    const cusIdRef = db.collection("uidByCustomerId").doc(subId)
      await cusIdRef.set(
{
  uid: uid, tenantId: tenantId, email: email
}, {merge: true}
      );
    return subId;
  }

  else{// 3) どちらにも無い → Stripe作成 → 両方へ保存
  const customer = await stripe.customers.create({
    email,
    name,
    metadata: { tenantId, uid },
  });

  await tenantRef.set(
    {
      customerId: customer.id, // ← 正
      subscription: { ...(tData.subscription || {}), stripeCustomerId: customer.id }, // ← ミラー
    },
    { merge: true }
  );

  const cusIdRef = db.collection("uidByCustomerId").doc(customer.id)
      await cusIdRef.set(
{
  uid: uid, tenantId: tenantId, email: email
}, {merge: true}
      );

  await upsertTenantIndex(uid, tenantId);
  return customer.id;}
}

type DeductionRule = {
  percent: number;
  fixed: number;
  effectiveFrom?: FirebaseFirestore.Timestamp | null;
};



export const setAdminByEmail = functions
  .region("us-central1")
  .https.onCall(async (data, context) => {
    const callerEmail = context.auth?.token?.email;
    if (!callerEmail || !OWNER_EMAILS.has(callerEmail)) {
      throw new functions.https.HttpsError("permission-denied", "not allowed");
    }
    const email = (data.email as string)?.trim();
    const value = (data.value as boolean) ?? true;
    if (!email) {
      throw new functions.https.HttpsError("invalid-argument", "email required");
    }
    const user = await admin.auth().getUserByEmail(email);
    const claims = user.customClaims || {};
    claims.admin = value;
    await admin.auth().setCustomUserClaims(user.uid, claims);
    return { ok: true, uid: user.uid, email, admin: value };
  });

async function pickEffectiveRule(tenantId: string, at: Date, uid: string): Promise<DeductionRule> {
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
  const sd = (cur.data()?.storeDeduction as any) ?? {};
  return {
    percent: Number(sd.percent ?? 0),
    fixed: Number(sd.fixed ?? 0),
    effectiveFrom: null,
  };
}

async function sendTipNotification(
  tenantId: string,
  tipId: string,
  resendApiKey: string,
  uid: string,
): Promise<void> {
  // ベースURL（管理者ログイン）
  const APP_BASE = process.env.FRONTEND_BASE_URL ?? process.env.APP_BASE ?? "";

  // ------- tips ドキュメント（計算済みの内訳が入っている想定） -------
  const tipRef = db.collection(uid).doc(tenantId).collection("tips").doc(tipId);
  const tipSnap = await tipRef.get();
  if (!tipSnap.exists) return;
  const tip = tipSnap.data() ?? {};

  // -------- 金額・通貨と内訳（既に保存済みの値を使う） --------
  const currency = toUpperCurrency(tip.currency);
  const grossAmount = safeInt(tip.amount); // 元金（チップ総額）
  const fees = (tip.fees ?? {}) as any;
  const net = (tip.net ?? {}) as any;

  const stripeFee = safeInt(fees?.stripe?.amount);
  const platformFee = safeInt(fees?.platform);
  const storeDeduct = safeInt(net?.toStore);

  const money = (n: number) => fmtMoney(n, currency);

  // -------- 店舗情報 / 表示名 --------
  const tenSnap = await db.collection(uid).doc(tenantId).get();
  const tenantName =
    (tenSnap.get("name") as string | undefined) ||
    (tenSnap.get("tenantName") as string | undefined) ||
    "店舗";

  const isEmployee =
    (tip.recipient?.type === "employee") || Boolean(tip.employeeId);

  const employeeName =
    (tip.employeeName as string | undefined) ||
    (tip.recipient?.employeeName as string | undefined) ||
    "スタッフ";

  const displayName = isEmployee
    ? employeeName
    : (
        (tip.storeName as string | undefined) ||
        (tip.recipient?.storeName as string | undefined) ||
        tenantName
      );

  // -------- 送信先の収集（重複排除） --------
  const toSet = new Set<string>();

  // a) 宛先（従業員 or 店舗）
  if (isEmployee) {
    const empId: string | undefined =
      (tip.employeeId as string | undefined) ||
      (tip.recipient?.employeeId as string | undefined);
    if (empId) {
      try {
        const empSnap = await db.collection(uid).doc(tenantId)
          .collection("employees").doc(empId).get();
        const em = empSnap.get("email") as string | undefined;
        if (isLikelyEmail(em)) toSet.add(em.trim());
      } catch {}
    }
  } else {
    const storeEmail =
      (tip.storeEmail as string | undefined) ||
      (tip.recipient?.storeEmail as string | undefined);
    if (isLikelyEmail(storeEmail)) toSet.add(storeEmail!.trim());
  }

  // b) 通知用メール配列
  const notify = tenSnap.get("notificationEmails") as string[] | undefined;
  if (Array.isArray(notify)) {
    for (const e of notify) if (isLikelyEmail(e)) toSet.add(e.trim());
  }

  // c) ★ 店舗管理者（tenant ドキュメントの members 配列 = UID 配列）→ users/{uid}.email を収集
  await addEmailsFromTenantMembersArray({
    db,
    toSet,
    tenantSnap: tenSnap,
  });

  // d) フォールバック
  if (toSet.size === 0) {
    const fallback =
      (tip.employeeEmail as string | undefined) ||
      (tip.recipient?.employeeEmail as string | undefined) ||
      (tip.storeEmail as string | undefined);
    if (isLikelyEmail(fallback)) toSet.add(fallback.trim());
  }

  const to = Array.from(toSet);
  if (to.length === 0) {
    console.warn("[tip mail] no recipient", { tenantId, tipId });
    return;
  }

  // -------- 付加情報（任意） --------
  const payerMessage =
    (typeof tip.payerMessage === "string" && tip.payerMessage.trim()) ||
    (typeof tip.senderMessage === "string" && tip.senderMessage.trim()) ||
    "";

  const createdAt: Date =
    (tip.createdAt?.toDate?.() as Date | undefined) ||
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
      : `<em>(アプリURL未設定)</em>`
    }
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
  const { Resend } = await import("resend");
  const resend = new Resend(resendApiKey);
  await resend.emails.send({
    from: "TIPRI チップリ <sendtip_app@appfromkomeda.jp>",
    to,
    subject,
    text,
    html,
  });

  // -------- 送信記録 --------
  await tipRef.set(
    {
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
    },
    { merge: true }
  );
}

/* ========= ヘルパー ========= */

function isLikelyEmail(x: unknown): x is string {
  return typeof x === "string" && x.includes("@") && !/\s/.test(x);
}

async function addEmailsFromTenantMembersArray(params: {
  db: FirebaseFirestore.Firestore;
  toSet: Set<string>;
  tenantSnap: FirebaseFirestore.DocumentSnapshot;
}) {
  const { db, toSet, tenantSnap } = params;

  // tenant ドキュメントの members (UID配列)
  const members = tenantSnap.get("members") as unknown;
  if (!Array.isArray(members) || members.length === 0) return;

  // UID を正規化 & 重複排除
  const uids = Array.from(
    new Set(
      members
        .map((v) => (typeof v === "string" ? v.trim() : ""))
        .filter((v) => v.length > 0)
    )
  );
  if (uids.length === 0) return;

  const usersCol = db.collection("users");
  const idField = admin.firestore.FieldPath.documentId();

  // 'in' 条件の 10 件制限に合わせて分割
  for (let i = 0; i < uids.length; i += 10) {
    const batch = uids.slice(i, i + 10);
    try {
      const qs = await usersCol.where(idField, "in", batch).get();
      for (const doc of qs.docs) {
        const em = (doc.get("email") as string | undefined) ?? undefined;
        if (isLikelyEmail(em)) toSet.add(em.trim());
      }
    } catch {
      // フォールバック：個別 get()
      await Promise.all(
        batch.map(async (u) => {
          try {
            const s = await usersCol.doc(u).get();
            const em = (s.get("email") as string | undefined) ?? undefined;
            if (isLikelyEmail(em)) toSet.add(em.trim());
          } catch {}
        })
      );
    }
  }
}


type UidByCustomerIdDoc = {
  uid?: string;
  tenantId?: string;
  email?: string;
};



function yen(n: number | null | undefined): string {
  const v = typeof n === "number" ? n : 0;
  return `¥${Number(v).toLocaleString("ja-JP")}`;
}

function tsFromSec(sec?: number | null) {
  if (!sec && sec !== 0) return null;
  return admin.firestore.Timestamp.fromMillis(sec * 1000);
}

function fmtDate(d: Date | admin.firestore.Timestamp | null | undefined): string {
  try {
    const date =
      d instanceof admin.firestore.Timestamp ? d.toDate() :
      d instanceof Date ? d : undefined;
    return date ? date.toLocaleString("ja-JP") : "-";
  } catch {
    return "-";
  }
}

// Firestore へ保存する統一スキーマを生成
function mapSubToRecord(sub: Stripe.Subscription) {
  const firstItem = sub.items?.data?.[0];
  const price = firstItem?.price as Stripe.Price | undefined;
  const product =
    (price?.product as Stripe.Product | undefined)?.id ??
    (typeof price?.product === "string" ? price?.product : null);

  // number 型だけ保存（null で未設定を明確化）
  const trialStart = typeof sub.trial_start === "number" ? sub.trial_start : null;
  const trialEnd = typeof sub.trial_end === "number" ? sub.trial_end : null;

  // 顧客ID
  const customerId =
    (typeof sub.customer === "string" ? sub.customer : sub.customer?.id) ?? null;

  // メタデータのプラン表記を最優先（なければ Price/Product 名から推定してもよい）
  const planFromMeta = (sub.metadata?.plan || "").trim();
  const normalizedPlan = planFromMeta || ""; // ここは任意。必要なら price.nickname などから推定してもOK

  return {
    stripeSubscriptionId: sub.id,
    stripeCustomerId: customerId,
    status: sub.status, // 'trialing' | 'active' | 'past_due' | 'canceled' | ...

    // 期間系（epoch seconds）
    currentPeriodStart: sub.current_period_start ?? null,
    currentPeriodEnd: sub.current_period_end ?? null,

    // トライアル系
    trialStart,
    trialEnd,

    // キャンセル系
    cancelAt: sub.cancel_at ?? null,
    cancelAtPeriodEnd: !!sub.cancel_at_period_end,

    // プラン/価格
    plan: normalizedPlan || null,
    priceId: price?.id ?? null,
    productId: product ?? null,

    // 参考情報
    latestInvoiceId:
      (typeof sub.latest_invoice === "string"
        ? sub.latest_invoice
        : sub.latest_invoice?.id) ?? null,
    collectionMethod: sub.collection_method ?? null,

    // 常にサーバ時刻で上書き
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  };
}


const toUpperCurrency = (c: unknown): string =>
  typeof c === "string" ? c.toUpperCase() : "JPY";

const safeInt = (n: unknown): number =>
  typeof n === "number" && Number.isFinite(n) ? Math.trunc(n) : 0;

const fmtMoney = (amt: number, ccy: string) =>
  ccy === "JPY" ? `¥${Number(amt || 0).toLocaleString("ja-JP")}` : `${amt} ${ccy}`;



/* ===================== agency ===================== */
export const adminSetAgencyPassword = onCall(
  {
    region: 'us-central1',
    memory: '256MiB',
    cors: ALLOWED_ORIGINS.length ? ALLOWED_ORIGINS : true, // 何も無ければ全許可
  },
  async (req) => {
 
  

    const agentId = String(req.data?.agentId ?? '').trim();
    const newPassword = String(req.data?.password ?? '');

    if (!agentId || !newPassword) {
      throw new HttpsError('invalid-argument', 'agentId/password required');
    }
    if (newPassword.length < 8) {
      throw new HttpsError('invalid-argument', 'password too short (>=8)');
    }

    const ref = db.collection('agencies').doc(agentId);
    const snap = await ref.get();
    if (!snap.exists) throw new HttpsError('not-found', 'agency not found');

    const salt = await bcrypt.genSalt(10);
    const passwordHash = await bcrypt.hash(newPassword, salt);

    await ref.set(
      {
        passwordHash,
        passwordSetAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );

    return { ok: true };
  }
);


export const agentLogin = onCall(
  {
    region: "us-central1",
    memory: "256MiB",
    // 許可するオリジン
    cors: ALLOWED_ORIGINS,
  },
  async (req) => {
    try {
      const rawCode = (req.data?.code || "").toString().trim();
      const password = (req.data?.password || "").toString();

      if (!rawCode || !password) {
        throw new HttpsError("invalid-argument", "code/password required");
      }

      // ※ 必要なら UID として安全な文字に正規化（任意）
      //   大文字小文字ゆらぎや空白・記号対策。要件に合わせて調整。
      const code = rawCode.toLowerCase();

      // code はユニーク想定
      const qs = await db.collection("agencies").where("code", "==", rawCode).limit(1).get();
      if (qs.empty) throw new HttpsError("not-found", "agency not found");

      const doc = qs.docs[0];
      const agentId = doc.id;
      const m = (doc.data() || {}) as Record<string, unknown>;

      if (((m.status as string) || "active") !== "active") {
        throw new HttpsError("failed-precondition", "agency suspended");
      }

      const hash = (m.passwordHash as string) || "";
      if (!hash) throw new HttpsError("failed-precondition", "password not set");

      const ok = await bcrypt.compare(password, hash);
      if (!ok) throw new HttpsError("permission-denied", "invalid credentials");

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
      } catch {
        await admin.auth().createUser({
          uid: agentUid,
          displayName: (m.name as string) || `Agent ${rawCode}`,
        });
      }

      const token = await admin.auth().createCustomToken(agentUid, additionalClaims);

      await doc.ref.set(
        { lastLoginAt: admin.firestore.FieldValue.serverTimestamp() },
        { merge: true }
      );

      return {
        token,
        uid: agentUid,                 // ← 返却しておくとフロントで扱いやすい
        agentId,
        agentName: (m.name as string) || "",
        agent: true
      };
    } catch (err: any) {
      logger.error("agentLogin failed", err);
      if (err instanceof HttpsError) throw err;
      throw new HttpsError("internal", err?.message ?? "internal error");
    }
  }
);


/* ===================== tenant-admin ===================== */
export async function assertTenantAdmin(tenantId: string, uid: string) {
  // ルート: {collection: <uid>, doc: <tenantId>}
  const tRef = db.collection(uid).doc(tenantId);
  const tSnap = await tRef.get();
  if (!tSnap.exists) {
    throw new functions.https.HttpsError("not-found", "Tenant not found");
  }
  const data = tSnap.data() || {};

 
  const members = (data.members ?? []) as any[];
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
    if (inMembers) return;
  }

  throw new functions.https.HttpsError("permission-denied", "Not tenant admin");
}

export const inviteTenantAdmin = onCall(
  {
    region: "us-central1",
    memory: "256MiB",
    secrets: [RESEND_API_KEY],
  },
  async (req) => {
    const uid = req.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in");

    const tenantId: string = (req.data?.tenantId || "").toString();
    const emailRaw: string = (req.data?.email || "").toString();
    const emailLower = emailRaw.trim().toLowerCase();
    if (!tenantId || !emailLower.includes("@")) {
      throw new HttpsError("invalid-argument", "bad tenantId/email");
    }

    // 権限チェック
    await assertTenantAdmin(tenantId, uid);

    // ===== 追加: 店舗名と招待者名を取得 =====
    // 店舗名（name / tenantName のどちらかが入っている想定）
    const tenSnap = await db.collection(uid).doc(tenantId).get();
    const tenantName =
      (tenSnap.get("name") as string | undefined) ||
      (tenSnap.get("tenantName") as string | undefined) ||
      "店舗";

    // 招待者表示名（なければメール、どちらも無ければUID）
    let inviterDisplay =
      (req.auth?.token?.name as string | undefined) ||
      (req.auth?.token?.email as string | undefined) ||
      "";
    if (!inviterDisplay) {
      try {
        const inviterUser = await admin.auth().getUser(uid);
        inviterDisplay =
          inviterUser.displayName || inviterUser.email || `UID:${uid}`;
      } catch {
        inviterDisplay = `UID:${uid}`;
      }
    }

    // すでにメンバーなら終了（既存処理）
    const userByEmail = await admin.auth().getUserByEmail(emailLower).catch(() => null);
    if (userByEmail) {
      const memberRef = db.doc(`${uid}/${tenantId}/members/${userByEmail.uid}`);
      const mem = await memberRef.get();
      if (mem.exists) return { ok: true, alreadyMember: true };
    }

    // 招待トークン作成（既存処理）
    const token = crypto.randomBytes(32).toString("hex");
    const tokenHash = sha256(token);
    const expiresAt = admin.firestore.Timestamp.fromDate(
      new Date(Date.now() + 1000 * 60 * 60 * 24 * 7)
    );

    const invitesCol = db.collection(`${uid}/${tenantId}/invites`);
    const existing = await invitesCol
      .where("emailLower", "==", emailLower)
      .where("status", "==", "pending")
      .limit(1)
      .get();

    let inviteRef: FirebaseFirestore.DocumentReference;
    if (existing.empty) {
      inviteRef = invitesCol.doc();
      await inviteRef.set({
        emailLower,
        tokenHash,
        status: "pending",
        invitedBy: {
          uid,
          email: (req.auth?.token?.email as string) || null,
          name: inviterDisplay, // ←保存しておくと後で見れて便利
        },
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        expiresAt,
        tenantName, // ←参考用に保存（任意）
      });
    } else {
      inviteRef = existing.docs[0].ref;
      await inviteRef.update({
        tokenHash,
        expiresAt,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        tenantName, // ←上書き（任意）
      });
    }

    // 送信
    const { Resend } = await import("resend");
    const resend = new Resend(RESEND_API_KEY.value());

    // 受諾URLは既存のまま
const acceptUrl = `${APP_ORIGIN}/#/admin-invite?tenantId=${encodeURIComponent(
  tenantId
)}&token=${encodeURIComponent(token)}`;

// ▼ 件名・本文を指定の文面に差し替え
const subject =
  "【TIPRI チップリ】店舗管理者として招待されました。内容を確認をお願いいたします。";

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


    await inviteRef.set(
      { emailedAt: admin.firestore.FieldValue.serverTimestamp() },
      { merge: true }
    );

    return { ok: true };
  }
);



export const acceptTenantAdminInvite = functions.https.onCall(async (data, context) => {
  const authedUid = context.auth?.uid;
  const email = ((context.auth?.token?.email as string) || "").toLowerCase();
  if (!authedUid || !email) throw new functions.https.HttpsError("unauthenticated", "Sign in");

  const tenantId = (data?.tenantId || "").toString();
  const token = (data?.token || "").toString();
  if (!tenantId || !token) {
    throw new functions.https.HttpsError("invalid-argument", "tenantId/token required");
  }

  // ★ オーナー uid を tenantIndex から取得
  const idx = await db.collection("tenantIndex").doc(tenantId).get();
  if (!idx.exists) throw new functions.https.HttpsError("not-found", "tenantIndex not found");
  const ownerUid = (idx.data() as any).uid as string;

  const tokenHash = sha256(token);
  const q = await db
    .collection(`${ownerUid}/${tenantId}/invites`) // ★ ownerUid 配下
    .where("tokenHash", "==", tokenHash)
    .limit(1)
    .get();
  if (q.empty) throw new functions.https.HttpsError("not-found", "Invite not found");

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
    tx.set(
      memRef,
      {
        role: "admin",
        email,
        displayName: (context.auth?.token?.name as string) || null,
        addedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );

    // tenant ドキュメントに UID を積む
    tx.set(
      tRef,
      { memberUids: admin.firestore.FieldValue.arrayUnion(authedUid) },
      { merge: true }
    );

    // 招待を accepted に
    tx.update(inviteDoc.ref, {
      status: "accepted",
      acceptedAt: admin.firestore.FieldValue.serverTimestamp(),
      acceptedBy: { uid: authedUid, email },
    });

    // ★ 追加: 承認ユーザー側に { ownerUid, tenantId } を保存
    // 複数テナントに対応できるよう、tenants.<tenantId> に入れて merge
    tx.set(
      invitedRef,
      {
        tenants: {
          [tenantId]: {
            ownerUid,
            tenantId,
            acceptedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
        },
      },
      { merge: true }
    );
  });

  return { ok: true };
});



export const cancelTenantAdminInvite = functions.https.onCall(async (data, context) => {
  const actorUid = context.auth?.uid;
  if (!actorUid) throw new functions.https.HttpsError("unauthenticated", "Sign in");

  const tenantId = (data?.tenantId || "").toString();
  const inviteId = (data?.inviteId || "").toString();
  if (!tenantId || !inviteId) {
    throw new functions.https.HttpsError("invalid-argument", "tenantId/inviteId required");
  }

  // ★ tenantIndex からオーナー uid を取得
  const idx = await db.collection("tenantIndex").doc(tenantId).get();
  if (!idx.exists) throw new functions.https.HttpsError("not-found", "tenantIndex not found");
  const ownerUid = (idx.data() as any).uid as string;

  // ★ 権限チェック：オーナー名前空間のテナントで、呼び出しユーザーが admin/owner か
  const tSnap = await db.collection(ownerUid).doc(tenantId).get();
  if (!tSnap.exists) throw new functions.https.HttpsError("not-found", "Tenant not found");

  const members = (tSnap.data()?.members ?? []) as any[];
  const isAdmin =
    Array.isArray(members) &&
    members.some((m) => {
      if (typeof m === "string") return m === actorUid;
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


/* ===================== tip ===================== */
export const createTipSessionPublic = functions
  .region("us-central1")
  .runWith({
    secrets: ["STRIPE_SECRET_KEY", "FRONTEND_BASE_URL"],
    memory: "256MB",
  })
  .https.onCall(async (data) => {
    const { tenantId, employeeId, amount, memo = "Tip", payerMessage } = data as {
      tenantId?: string;
      employeeId?: string;
      amount?: number;
      memo?: string;
      payerMessage?: string;
    };

    if (!tenantId || !employeeId) {
      throw new functions.https.HttpsError("invalid-argument", "tenantId/employeeId required");
    }
    if (!Number.isInteger(amount) || (amount ?? 0) <= 0 || (amount as number) > 1_000_000) {
      throw new functions.https.HttpsError("invalid-argument", "invalid amount");
    }

    // uid を逆引きして uid/{tenantId} を参照
    const tRef = await tenantRefByIndex(tenantId);
    const uid = tRef.parent.id;
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
    const tenantName = (tDoc.data()?.name as string | undefined) ?? "";

    const sub = (tDoc.data()?.subscription ?? {}) as { plan?: string; feePercent?: number };
    const plan = (sub.plan ?? "A").toUpperCase();
    const percent =
      typeof sub.feePercent === "number" ? sub.feePercent : plan === "B" ? 20 : plan === "C" ? 15 : 35;

    const appFee = calcApplicationFee(amount!, { percent, fixed: 0 });

    const tipRef = tRef.collection("tips").doc();
    await tipRef.set({
      tenantId,
      employeeId,
      amount,
      payerMessage,
      currency: "JPY",
      status: "pending",
      recipient: { type: "employee", employeeId, employeeName },
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    const stripe = stripeClient();
    const FRONTEND_BASE_URL = requireEnv("FRONTEND_BASE_URL").replace(/\/+$/, "");

    const successUrl =
      `${FRONTEND_BASE_URL}#/p` +
      `?t=${encodeURIComponent(tenantId)}` +
      `&thanks=true` +
      `&amount=${encodeURIComponent(String(amount!))}` +
      `&employeeName=${encodeURIComponent(employeeName)}` +
      `&tenantName=${encodeURIComponent(tenantName)}`;

    const cancelUrl =
      `${FRONTEND_BASE_URL}#/p` +
      `?t=${encodeURIComponent(tenantId)}` +
      `&canceled=true`;

    // ---- Direct charges: 接続アカウントでセッション作成（stripeAccount: acctId）----
    const session = await stripe.checkout.sessions.create(
      {
        mode: "payment",
         
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
          // アプリ手数料は Direct でも有効（プラットフォームに入る）
          application_fee_amount: appFee,
          
        },
      },
      {
        // ← これが Direct charges の肝
        stripeAccount: acctId,
      }
    );

    return { checkoutUrl: session.url, sessionId: session.id, tipDocId: tipRef.id };
  });



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

    if (!tenantId) throw new functions.https.HttpsError("invalid-argument", "tenantId required");
    if (!Number.isInteger(amount) || (amount ?? 0) <= 0 || (amount as number) > 1_000_000) {
      throw new functions.https.HttpsError("invalid-argument", "invalid amount");
    }

    const tRef = await tenantRefByIndex(tenantId);
    const tDoc = await tRef.get();
    if (!tDoc.exists || tDoc.data()!.status !== "active") {
      throw new functions.https.HttpsError("failed-precondition", "Tenant suspended or not found");
    }

    const acctId = tDoc.data()?.stripeAccountId as string | undefined;
    if (!acctId) throw new functions.https.HttpsError("failed-precondition", "Store not connected to Stripe");
    const chargesEnabled = !!tDoc.data()?.connect?.charges_enabled;
    if (!chargesEnabled) {
      throw new functions.https.HttpsError("failed-precondition", "Store Stripe account is not ready (charges_disabled)");
    }

    const sub = (tDoc.data()?.subscription ?? {}) as { plan?: string; feePercent?: number };
    const plan = (sub.plan ?? "A").toUpperCase();
    const percent = typeof sub.feePercent === "number" ? sub.feePercent : (plan === "B" ? 20 : plan === "C" ? 15 : 35);
    const appFee = calcApplicationFee(amount!, { percent, fixed: 0 });

    const storeName = (tDoc.data()?.name as string | undefined) ?? tenantId;

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

    const BASE = requireEnv("FRONTEND_BASE_URL").replace(/\/+$/, "");
    const successParams = new URLSearchParams({
      t: tenantId,
      thanks: "true",
      tenantName: storeName,
      amount: String(amount!),
    }).toString();
    const cancelParams = new URLSearchParams({
      t: tenantId,
      canceled: "true",
      tenantName: storeName,
    }).toString();
    const successUrl = `${BASE}#/p?${successParams}`;
    const cancelUrl  = `${BASE}#/p?${cancelParams}`;

    // ---- Direct charges: 接続アカウントでセッション作成（stripeAccount: acctId）----
    const session = await stripe.checkout.sessions.create(
      {
        mode: "payment",
  
        line_items: [
          {
            price_data: {
              currency: "jpy",
              product_data: { name: memo || `Tip to store ${storeName}` },
              unit_amount: amount!,
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
          application_fee_amount: appFee,
          
        },
      },
      {
        // ← これが Direct charges の肝
        stripeAccount: acctId,
      }
    );

    return { checkoutUrl: session.url, sessionId: session.id, tipDocId: tipRef.id };
  });




/* ===================== send-email ===================== */
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

export async function sendInvoiceNotificationByCustomerId(
  customerId: string,
  inv: Stripe.Invoice,
  resendApiKey: string
): Promise<void> {
  // 1) mapping を最初に参照
  const mapSnap = await db.collection("uidByCustomerId").doc(customerId).get();
  let map: UidByCustomerIdDoc = (mapSnap.exists ? (mapSnap.data() as any) : {}) || {};
  let uid: string | undefined = typeof map.uid === "string" ? map.uid : undefined;
  let tenantId: string | undefined = typeof map.tenantId === "string" ? map.tenantId : undefined;
  const mappedEmail: string | undefined = typeof map.email === "string" ? map.email : undefined;

  // Fallback: tenantIndex 全走査（互換のため。将来は不要化可）
  if (!uid || !tenantId) {
    const idxSnap = await db.collection("tenantIndex").get();
    for (const d of idxSnap.docs) {
      const data: any = d.data() || {};
      if ((data.subscription?.stripeCustomerId as string | undefined) === customerId) {
        uid = data.uid as string | undefined;
        tenantId = data.tenantId as string | undefined;
        break;
      }
    }
  }
  if (!uid || !tenantId) {
    console.warn("[invoice mail] mapping not found for customerId:", customerId);
    return;
  }

  // 2) 店舗名の解決（優先: tenant → 次: tenantIndex）
  let tenantName: string | undefined;
  try {
    const tenSnap = await db.collection(uid).doc(tenantId).get();
    tenantName = (tenSnap.get("name") as string | undefined) ||
                 (tenSnap.get("tenantName") as string | undefined) ||
                 undefined;
  } catch {}
  if (!tenantName) {
    try {
      const idx = await db.collection("tenantIndex").doc(tenantId).get();
      tenantName = (idx.get("name") as string | undefined) ||
                   (idx.get("tenantName") as string | undefined) ||
                   undefined;
    } catch {}
  }
  tenantName ||= "店舗";

  // 3) 宛先の収集（重複削除）
  const toSet = new Set<string>();

  // (a) mapping の email
  if (mappedEmail && mappedEmail.includes("@")) toSet.add(mappedEmail);

  // (b) tenant.notificationEmails
  try {
    const tenSnap = await db.collection(uid).doc(tenantId).get();
    const notify = tenSnap.get("notificationEmails") as string[] | undefined;
    if (Array.isArray(notify)) {
      for (const e of notify) if (typeof e === "string" && e.includes("@")) toSet.add(e);
    }
  } catch {}

  // (c) members の admin/owner
  try {
    const memSnap = await db.collection(uid).doc(tenantId).collection("members").get();
    for (const m of memSnap.docs) {
      const md = m.data() || {};
      const role = String(md.role ?? "admin").toLowerCase();
      if (role === "admin" || role === "owner") {
        const em = md.email as string | undefined;
        if (em && em.includes("@")) toSet.add(em);
      }
    }
  } catch {}

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
  const periodStart = tsFromSec((line0?.start as any) ?? inv.created);
  const periodEnd = tsFromSec((line0?.end as any) ?? inv.created);
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
  const { Resend } = await import("resend");
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
    await db.collection(uid).doc(tenantId).collection("invoices").doc(inv.id).set(
      {
        _mail: {
          sentAt: admin.firestore.FieldValue.serverTimestamp(),
          to: recipients,
          subject,
        },
      },
      { merge: true }
    );
  } catch {}
}


//* ===================== Stripe Webhook ===================== */
export const stripeWebhook = functions
  .region("us-central1")
  .runWith({
    secrets: [
      "STRIPE_SECRET_KEY",
      "STRIPE_WEBHOOK_SECRET",
      "STRIPE_CONNECT_WEBHOOK_SECRET",
      "FRONTEND_BASE_URL",
      "STRIPE_PAYMENT_WEBHOOK_SECRET",
      "INITIAL_FEE_PRICE_ID", 
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

    // ===== 安全変換ヘルパ =====
    const toMillis = (sec: unknown): number | null => {
      if (typeof sec === "number" && Number.isFinite(sec)) return Math.trunc(sec * 1000);
      if (typeof sec === "string" && sec !== "") {
        const n = Number(sec);
        if (Number.isFinite(n)) return Math.trunc(n * 1000);
      }
      return null;
    };
    const tsFromSec = (sec: unknown) => {
      const ms = toMillis(sec);
      return ms !== null ? admin.firestore.Timestamp.fromMillis(ms) : null;
    };
    const nowTs = () => admin.firestore.Timestamp.now();
    const putIf = <T extends object>(v: unknown, obj: T) =>
      v !== null && v !== undefined ? obj : ({} as T);

    let event: Stripe.Event | null = null;
    for (const secret of secrets) {
      try {
        event = stripe.webhooks.constructEvent((req as any).rawBody, sig, secret);
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

    const requestOptions: Stripe.RequestOptions | undefined = event.account
      ? { stripeAccount: event.account as string }
      : undefined;

    const type = event.type;
    const docRef = db.collection("webhookEvents").doc(event.id);
    await docRef.set({
      type,
      receivedAt: admin.firestore.FieldValue.serverTimestamp(),
      handled: false,
    });

    // ★ 両方へ保存する小ヘルパ（{uid}/{tenantId} と tenantIndex）
    async function writeIndexAndOwner(
      uid: string,
      tenantId: string,
      patch: FirebaseFirestore.DocumentData
    ) {
      await Promise.all([
        db.collection(uid).doc(tenantId).set(patch, { merge: true }),
        db.collection("tenantIndex").doc(tenantId).set({ ...patch, uid, tenantId }, { merge: true }),
      ]);
    }

    try {
      /* ========== 1) Checkout 完了 ========== */
      if (type === "checkout.session.completed") {
  const session = event.data.object as Stripe.Checkout.Session;

  // ===== Connect 文脈の決定 =====
  // event.account があれば、その接続アカウントで作られた決済（Direct の可能性が高い）
  const connectAcctId = (event as any).account as string | undefined;
  // PaymentIntent/PaymentMethod/Charge を取得する時にだけ使う（Subscriptionには使わない）
  const requestOptionsPayment = connectAcctId ? { stripeAccount: connectAcctId } : undefined;

  if (session.mode === "setup") {
    try {
      const tenantId = session.metadata?.tenantId as string | undefined;
      const plan     = session.metadata?.plan     as string | undefined;
      const uidMeta  = session.metadata?.uid      as string | undefined;
      const setupIntentId = session.setup_intent as string | undefined;
      const customerId    = session.customer as string | undefined;

      if (!tenantId || !plan || !setupIntentId || !customerId) {
        console.warn("[setup completed] missing params", { tenantId, plan, setupIntentId, customerId });
        await docRef.set({ handled: true }, { merge: true });
        res.sendStatus(200);
        return;
      }

      // 1) PM を Customer の default に設定
      const si = await stripe.setupIntents.retrieve(setupIntentId);
      const pm = si.payment_method as string | undefined;
      if (pm) {
        await stripe.customers.update(customerId, {
          invoice_settings: { default_payment_method: pm },
        });
      }

      // 2) プランの price を取得（あなたの billingPlans から）
      const planSnap = await db.collection("billingPlans").doc(String(plan)).get();
      const priceId = (planSnap.exists ? planSnap.data()?.stripePriceId : undefined) as string | undefined;
      if (!priceId) {
        console.error("[setup completed] no priceId for plan", plan);
        await docRef.set({ handled: true }, { merge: true });
        res.sendStatus(200);
        return;
      }

      // 3) 初期費用 price
      const INITIAL_FEE_PRICE_ID = process.env.INITIAL_FEE_PRICE_ID!;
      const TRIAL_DAYS = 30;

      // 4) 購読を作成（★add_invoice_items で“トライアル終了後の最初の請求書”に初期費用を同梱）
      const idemKey = `sub_create_from_setup_${session.id}`;
      const createdSub = await stripe.subscriptions.create(
        {
          customer: customerId,
          items: [{ price: priceId, quantity: 1 }],
          trial_period_days: TRIAL_DAYS,
          add_invoice_items: [{ price: INITIAL_FEE_PRICE_ID }],
          payment_behavior: "default_incomplete", // 安全側。trial中は即請求されません
          metadata: { tenantId, plan, uid: uidMeta ?? "" },
        },
        { idempotencyKey: idemKey }
      );

      // 5) Firestore 反映（ここで“登録完了”とみなせる状態に）
      let uid = uidMeta;
      if (!uid) {
        const tRefIdx = await tenantRefByIndex(tenantId);
        uid = tRefIdx.parent!.id;
      }
      const periodEndTs = tsFromSec(createdSub.current_period_end);
      await tenantRefByUid(uid!, tenantId).set(
        {
          subscription: {
            plan,
            status: createdSub.status, // 通常 "trialing"
            stripeCustomerId: customerId,
            stripeSubscriptionId: createdSub.id,
            ...(periodEndTs ? { currentPeriodEnd: periodEndTs, nextPaymentAt: periodEndTs } : {}),
            overdue: createdSub.status === "past_due" || createdSub.status === "unpaid",
            trial: {
              status: "trialing",
              ...(tsFromSec(createdSub.trial_start) ? { trialStart: tsFromSec(createdSub.trial_start)! } : {}),
              ...(tsFromSec(createdSub.trial_end)   ? { trialEnd:   tsFromSec(createdSub.trial_end)!   } : {}),
            },
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
          // 任意：一時フラグを落とす用
          provisioning: admin.firestore.FieldValue.delete(),
        },
        { merge: true }
      );

      await docRef.set({ handled: true }, { merge: true });
      res.sendStatus(200);
      return;
    } catch (e) {
      console.error("[setup completed] failed to create subscription:", e);
      // ここは 200 でも可（Stripe が再送してくるため）。あなたの運用に合わせて。
      res.sendStatus(200);
      return;
    }
  }
  

  // ===== A. サブスク =====
  if (session.mode === "subscription") {
    const tenantId = session.metadata?.tenantId as string | undefined;
    const uidMeta = session.metadata?.uid as string | undefined;
    const plan = session.metadata?.plan as string | undefined;
    const subscriptionId = session.subscription as string | undefined;
    const customerId = (session.customer as string | undefined) ?? undefined;

    if (!tenantId || !subscriptionId) {
      console.error("subscription checkout completed but missing tenantId or subscriptionId");
    } else {
      // ★ Subscription は通常プラットフォーム側のオブジェクト。
      //   ここでは requestOptions を付けない（付けると No such subscription になり得る）
      const sub = await stripe.subscriptions.retrieve(subscriptionId);

      let feePercent: number | undefined;
      if (plan) {
        const planSnap = await db.collection("billingPlans").doc(String(plan)).get();
        feePercent = planSnap.exists ? (planSnap.data()?.feePercent as number | undefined) : undefined;
      }

      // uid 確定
      let uid = uidMeta;
      if (!uid) {
        const tRefIdx = await tenantRefByIndex(tenantId);
        uid = tRefIdx.parent!.id;
      }

      const periodEndTs = tsFromSec((sub as Stripe.Subscription).current_period_end);

      await tenantRefByUid(uid!, tenantId).set(
        {
          subscription: {
            plan,
            status: sub.status,
            stripeCustomerId: customerId,
            stripeSubscriptionId: sub.id,
            ...putIf(periodEndTs, { currentPeriodEnd: periodEndTs!, nextPaymentAt: periodEndTs! }),
            overdue: sub.status === "past_due" || sub.status === "unpaid",
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

  // ===== B. 初期費用（mode=payment & kind=initial_fee） =====
  if (session.mode === "payment") {
    let tenantId =
      (session.metadata?.tenantId as string | undefined) ??
      (session.client_reference_id as string | undefined);

    let uidMeta = session.metadata?.uid as string | undefined;

    let isInitialFee = false;
    const paymentIntentId = session.payment_intent as string | undefined;
    if (paymentIntentId) {
      // ★ Direct の場合に備えて requestOptionsPayment を付与
      const pi = await stripe.paymentIntents.retrieve(paymentIntentId, requestOptionsPayment);
      const kind =
        (pi.metadata?.kind as string | undefined) ?? (session.metadata?.kind as string | undefined);
      if (!tenantId) tenantId = (pi.metadata?.tenantId as string | undefined) ?? undefined;
      if (!uidMeta) uidMeta = (pi.metadata?.uid as string | undefined) ?? undefined;
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
          billing: {
            initialFee: { status: "paid" },
          },
        },
        { merge: true }
      );


      await docRef.set({ handled: true }, { merge: true });
      
      try {
  // 1) 代理店リンク情報の取得（tenant doc の agency）
  const tSnap = await tRef.get();
  const agency = (tSnap.data()?.agency ?? {}) as any;
  const linked = agency?.linked === true;
  const commissionPercent = Number(agency?.commissionPercent ?? 0);
  const agentId = (agency?.agentId as string | undefined) ?? undefined;

  // 2) 代理店の Connect アカウントIDを agencies/{agentId} から取得
  let agencyAccountId: string | undefined;
  if (linked && agentId) {
    const agentDoc = await admin.firestore().collection('agencies').doc(agentId).get();
    agencyAccountId = (agentDoc.exists ? agentDoc.data()?.stripeAccountId : undefined) as (string | undefined);
  }

  // 3) 送金実行条件チェック
  const totalMinor = (session.amount_total ?? 0) as number; // JPY最小単位
  const pct = Math.max(0, Math.min(100, commissionPercent));
  const transferAmount = Math.floor(totalMinor * pct / 100);

  // 既に代理店送金済みならスキップ（再実行防止）
const already = (await tRef.get()).data()?.billing?.initialFee?.agencyTransfer?.id as (string | undefined);
if (!already && agencyAccountId && transferAmount > 0) {
  // 1) PaymentIntent から latest_charge を取得（charge.id が必要）
  const piId = session.payment_intent as string | undefined;
  if (!piId) {
    console.warn('No payment_intent on session for initial_fee; skip transfer.');
  } else {
    const pi = await stripe.paymentIntents.retrieve(piId, { expand: ['latest_charge'] });
    const latest = pi.latest_charge;
    const chargeId =
      typeof latest === 'string'
        ? latest
        : latest && typeof latest === 'object'
          ? (latest as Stripe.Charge).id
          : undefined;

    if (!chargeId) {
      console.warn(`No latest_charge on PI ${piId}; transfer skipped for now`);
    } else {
      // 2) transfer_group（あれば引き継ぎ）
      const transferGroup = (pi.transfer_group as string | undefined) ?? undefined;

      // 3) 代理店へ Transfer を“予約”（資金が available になったら自動で成立）
      //    - currency はチャージと同一
      //    - idempotency で二重送金を防止
      const idempotencyKey = `initialfee_transfer_${session.id}_${tenantId}_${agentId}`;
      const tr = await stripe.transfers.create(
        {
          amount: transferAmount,
          currency: (session.currency ?? 'jpy'),
          destination: agencyAccountId,
          ...(transferGroup ? { transfer_group: transferGroup } : {}),
          source_transaction: chargeId, // ★ これで available 待ちの“予約”になる
          metadata: {
            purpose: 'initial_fee_agency_commission',
            tenantId: tenantId!,
            agentId: agentId ?? '',
            checkoutSessionId: session.id,
            paymentIntentId: piId,
          },
        },
        { idempotencyKey }
      );

      // 4) Firestore へ記録（送金済みフラグ）
      await tRef.set(
        {
          billing: {
            initialFee: {
              agencyTransfer: {
                id: tr.id,
                amount: transferAmount,
                currency: (session.currency ?? 'jpy').toUpperCase(),
                destination: agencyAccountId,
                sourceCharge: chargeId,
                transferGroup: transferGroup ?? null,
                created: admin.firestore.FieldValue.serverTimestamp(),
              },
            },
          },
        },
        { merge: true }
      );
    }
  }
}

} catch (e) {
  console.error('Failed to transfer commission to agency:', e);
}
res.sendStatus(200);
      return;
    }
  }

  // ===== C. チップ（mode=payment の通常ルート） =====
  const sid = session.id;
  const tenantIdMeta = session.metadata?.tenantId as string | undefined;
  const employeeId = session.metadata?.employeeId as string | undefined;
  let employeeName = session.metadata?.employeeName as string | undefined;
  const payIntentId = session.payment_intent as string | undefined;
  let uid = session.metadata?.uid as string | undefined;

  const stripeCreatedSec = (session.created as number | undefined) ?? (event.created as number);
  const createdAtTs = tsFromSec(stripeCreatedSec) ?? nowTs();

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
      const eff = await pickEffectiveRule(tenantIdMeta, createdAtTs.toDate(), uid);
      const totalMinor = (session.amount_total ?? 0) as number;
      const { storeAmount, staffAmount } = splitMinor(totalMinor, eff.percent, eff.fixed);

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

    // ===== 料金・決済手段の詳細を付与（必要なときだけ retrieve） =====
    try {
      if (payIntentId) {
        const pi = await stripe.paymentIntents.retrieve(
          payIntentId,
          {
            expand: ["payment_method", "latest_charge", "latest_charge.balance_transaction"],
          },
          // ★ Direct の場合のみ requestOptionsPayment を使う（Destination/Platform でも harmless）
        // @ts-ignore stripe-node 型では第3引数 requestOptions だが overload により OK
          requestOptionsPayment
        );

        const latestCharge =
          (typeof pi.latest_charge === "object" ? (pi.latest_charge as Stripe.Charge) : null) || null;

        // Stripe手数料など
        const bt = latestCharge?.balance_transaction as Stripe.BalanceTransaction | undefined;
        const stripeFee = bt?.fee ?? 0;
        const stripeFeeCurrency =
          bt?.currency?.toUpperCase() ?? (session.currency ?? "jpy").toUpperCase();

        const appFeeAmount = latestCharge?.application_fee_amount ?? 0;

        const splitNow = (await tipRef.get()).data()?.split ?? {};
        const storeCut = (splitNow.storeAmount as number | undefined) ?? 0;

        const gross = (session.amount_total ?? 0) as number;
        const isStaff = !!employeeId;

        const toStore = isStaff ? storeCut : Math.max(0, gross  - stripeFee);
        const toStaff = isStaff ? Math.max(0, gross - stripeFee - storeCut) : 0;

        // 決済手段・カード要約
        let pm: Stripe.PaymentMethod | null = null;
        if (pi.payment_method && typeof pi.payment_method !== "string") {
          pm = pi.payment_method as Stripe.PaymentMethod;
        } else if (typeof pi.payment_method === "string") {
          try {
            pm = await stripe.paymentMethods.retrieve(pi.payment_method as string, requestOptionsPayment);
          } catch {
            pm = null;
          }
        }

        const pmd = latestCharge?.payment_method_details;
        const cardOnCharge = pmd?.type === "card" ? (pmd.card as any | undefined) : undefined;
        const cardOnPM = pm?.type === "card" ? pm.card : undefined;

        const paymentSummary: any = {
          method: pmd?.type || pm?.type || pi.payment_method_types?.[0],
          paymentIntentId: pi.id,
          chargeId:
            latestCharge?.id ||
            (typeof pi.latest_charge === "string" ? (pi.latest_charge as string) : null),
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
            threeDSecure:
              (cardOnCharge?.three_d_secure as any)?.result ??
              (pmd as any)?.card?.three_d_secure?.result ??
              null,
          };
        }

        await tipRef.set(
          {
            fees: {
              platform: appFeeAmount,
              stripe: {
                amount: stripeFee-appFeeAmount,
                currency: stripeFeeCurrency,
                balanceTransactionId: bt?.id ?? null,
              },
            },
            status: "succeeded",
            net: { toStore, toStaff },
            payment: paymentSummary,
            feesComputedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
          { merge: true }
        );
      }
    } catch (err) {
      console.error("Failed to enrich tip with stripe fee/payment details:", err);
    }
  }

  await docRef.set({ handled: true }, { merge: true });
  res.sendStatus(200);
  return;
}


      /* ========== 2) Checkout その他 ========== */
      if (
        type === "checkout.session.expired" ||
        type === "checkout.session.async_payment_failed"
      ) {
        const session = event.data.object as Stripe.Checkout.Session;
        const tenantId = session.metadata?.tenantId as string | undefined;
        if (tenantId) {
          let uid = session.metadata?.uid as string | undefined;
          if (!uid) {
            const tRefIdx = await tenantRefByIndex(tenantId);
            uid = tRefIdx.parent!.id;
          }
          
        }
      }

      /* ========== 3) 購読の作成/更新 ========== */
      if (
  type === "customer.subscription.created" ||
  type === "customer.subscription.updated"
) {
  const sub = event.data.object as Stripe.Subscription;

  let tenantId = sub.metadata?.tenantId as string | undefined;
  let uid = sub.metadata?.uid as string | undefined;
  const plan = sub.metadata?.plan as string | "";

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
    uid = tRefIdx.parent!.id;
  }

  const isTrialing = sub.status === "trialing";
  const trialStartTs = tsFromSec(sub.trial_start);
  const trialEndTs = tsFromSec(sub.trial_end);
  const periodEndTs = tsFromSec(sub.current_period_end);

  let feePercent: number | undefined;
  if (plan) {
    const planSnap = await db.collection("billingPlans").doc(String(plan)).get();
    feePercent = planSnap.exists
      ? (planSnap.data()?.feePercent as number | undefined)
      : undefined;
  }

  // ★ nextPaymentAt と overdue を追加し、両ドキュメントに反映
  const subPatch = {
    subscription: {
      plan,
      status: sub.status,
      stripeCustomerId: (sub.customer as string) ?? undefined,
      stripeSubscriptionId: sub.id,
      ...putIf(periodEndTs, { currentPeriodEnd: periodEndTs!, nextPaymentAt: periodEndTs! }),
      trial: {
        status: isTrialing ? "trialing" : "none",
        ...putIf(trialStartTs, { trialStart: trialStartTs! }),
        ...putIf(trialEndTs, { trialEnd: trialEndTs! }),
      },

      overdue: sub.status === "past_due" || sub.status === "unpaid", // ★追加
      ...(typeof feePercent === "number" ? { feePercent } : {}),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    status: plan == "" ? "nonactiva" : "active",
  };

  await writeIndexAndOwner(uid!, tenantId, subPatch);

  // ◆ 追記: 「トライアル中なら、初期費用を“次の請求書”に同梱」するための InvoiceItem を安全に作成
  try {
    const INITIAL_FEE_PRICE_ID = process.env.INITIAL_FEE_PRICE_ID!;
    if (INITIAL_FEE_PRICE_ID) {
      const tRef = tenantRefByUid(uid!, tenantId);
      const tSnap = await tRef.get();
      const tData = tSnap.data() || {};
      const initStatus: string | undefined = tData?.billing?.initialFee?.status;
      const pendingId: string | undefined = tData?.billing?.initialFee?.pendingInvoiceItemId;

      const needInitialFee = initStatus !== "paid";
      // ① trialing の時だけ仕込む
      // ② 既に pending の InvoiceItem を作っていないこと（冪等）
      if (isTrialing && needInitialFee && !pendingId) {
        const idemKey = `initfee_ii_for_sub_${sub.id}`;
        const ii = await stripe.invoiceItems.create(
          {
            customer: sub.customer as string,
            price: INITIAL_FEE_PRICE_ID,
            subscription: sub.id, // ← このサブスクの「次の請求書」に自動同梱される
            metadata: {
              tenantId,
              uid: uid!,
              kind: "initial_fee",
              for_subscription: sub.id,
            },
          },
          { idempotencyKey: idemKey }
        );

        await tRef.set(
          {
            billing: {
              initialFee: {
                status: "pending_on_first_invoice",
                pendingInvoiceItemId: ii.id, // ← 解約時に取り消すため保持
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
              },
            },
          },
          { merge: true }
        );
      }
    }
  } catch (e) {
    console.warn("[sub.created/updated] failed to prepare initial fee invoice item:", e);
  }
  // ◆ 追記ここまで

  // トライアル終了直後に再トライアル防止フラグを付与
  try {
    if (sub.status === "active" && typeof sub.trial_end === "number" && sub.trial_end * 1000 <= Date.now()) {
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
    const periodEndTs = tsFromSec(sub.current_period_end);
    const patch = {
      subscription: {
        status: "nonactive", // ★ ここを 'canceled' ではなく nonactive に正規化
        endedReason: "canceled", // 理由は別フィールドに保持
        endedAt: admin.firestore.FieldValue.serverTimestamp(),
        stripeSubscriptionId: sub.id,
        ...putIf(periodEndTs, { currentPeriodEnd: periodEndTs!, nextPaymentAt: periodEndTs! }),
        overdue: false,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        trial: { status: "none" },
      },

      status: "nonactive",
    };
    await writeIndexAndOwner(uid!, tenantId, patch);

    // ◆ 追記: トライアル中に作成していた pending の初期費用 InvoiceItem があれば取り消す
    try {
      const tRef = tenantRefByUid(uid!, tenantId);
      const tSnap = await tRef.get();
      const pendingId: string | undefined = tSnap.data()?.billing?.initialFee?.pendingInvoiceItemId;
      if (pendingId) {
        try {
          await stripe.invoiceItems.del(pendingId);
        } catch (_) {
          // 既に請求書に取り込まれている等で削除不能なら無視
        }
        await tRef.set(
          {
            billing: {
              initialFee: {
                // 解約時の表現は運用に合わせて調整可（ここでは pending をクリア）
                pendingInvoiceItemId: admin.firestore.FieldValue.delete(),
                // "none" / "canceled" など、運用の期待に応じて
                status: "none",
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
              },
            },
          },
          { merge: true }
        );
      }
    } catch (e) {
      console.warn("[sub.deleted] failed to clear pending initial fee invoice item:", e);
    }
  }
}


      /* ========== 4) 請求書（支払成功/失敗） ========== */
if (type === "invoice.payment_succeeded" || type === "invoice.payment_failed") {
  const inv = event.data.object as Stripe.Invoice;
  const customerId = inv.customer as string;
  const INITIAL_FEE_PRICE_ID = process.env.INITIAL_FEE_PRICE_ID!;

  // トライアル明け最初の課金を検出 → Customer にフラグ
  try {
    if (
      type === "invoice.payment_succeeded" &&
      inv.paid &&
      inv.billing_reason === "subscription_cycle" &&
      inv.subscription
    ) {
      const sub = await stripe.subscriptions.retrieve(inv.subscription as string);
      if (typeof sub.trial_end === "number" && sub.trial_end * 1000 <= Date.now()) {
        await stripe.customers.update(customerId, { metadata: { zotman_trial_used: "true" } });
      }
    }
  } catch (e) {
    console.warn("Failed to mark zotman_trial_used on invoice.payment_succeeded:", e);
  }

  // 既存のテナント検索・invoices 保存
  const idxSnap = await db.collection("tenantIndex").get();

  // この後の通知で使うために、処理対象の uid/tenantId を保持
  let foundUid: string | null = null;
  let foundTenantId: string | null = null;

  for (const d of idxSnap.docs) {
    const data: any = d.data();
    const uid = data.uid as string;
    const tenantId = data.tenantId as string;

    const t = await db.collection(uid).doc(tenantId).get();
    if (t.exists && t.get("subscription.stripeCustomerId") === customerId) {
      const createdTs = tsFromSec(inv.created) ?? nowTs();
      const line0 = inv.lines?.data?.[0]?.period;
      const psTs = tsFromSec((line0?.start as any) ?? inv.created) ?? createdTs;
      const peTs = tsFromSec((line0?.end as any) ?? inv.created) ?? createdTs;

      // invoices コレクションは従来どおり保存
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
            created: createdTs,
            period_start: psTs,
            period_end: peTs,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
          { merge: true }
        );

      // ★ 未払い/解消 と 次回再試行（失敗時）・直近請求サマリを保存（owner & index）
      const nextAttemptTs = tsFromSec(inv.next_payment_attempt);
      const subPatch =
        type === "invoice.payment_failed"
          ? {
              subscription: {
                overdue: true,
                latestInvoice: {
                  id: inv.id,
                  status: inv.status,
                  amountDue: inv.amount_due ?? null,
                  hostedInvoiceUrl: inv.hosted_invoice_url ?? null,
                },
                ...putIf(nextAttemptTs, { nextPaymentAttemptAt: nextAttemptTs! }),
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

      // ★ 初期費用（InvoiceItem）検出（ページング対応）
      try {
        const { hits, amount } = await pickInitialFeeLinesAll(stripe, inv, INITIAL_FEE_PRICE_ID);

        if (hits.length > 0) {
          const tRef = db.collection(uid).doc(tenantId);

          if (type === "invoice.payment_succeeded" && inv.paid === true) {
            // すでに paid 済みなら idempotent にスキップ
            const before = (await tRef.get()).data()?.billing?.initialFee?.status as
              | string
              | undefined;
            if (before !== "paid") {
              await tRef.set(
                {
                  billing: {
                    initialFee: {
                      status: "paid",
                      amount: amount, // 最小単位 (JPYなら円)
                      currency: (inv.currency ?? "jpy").toUpperCase(),
                      invoiceId: inv.id,
                      paidAt: admin.firestore.FieldValue.serverTimestamp(),
                      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                    },
                  },
                },
                { merge: true }
              );

              // tenantIndex にも要約を反映
              await db.collection("tenantIndex").doc(tenantId).set(
                {
                  billing: {
                    initialFee: {
                      status: "paid",
                      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                    },
                  },
                },
                { merge: true }
              );
            }
          } else if (type === "invoice.payment_failed") {
            // 失敗（未払い）を記録（必要に応じて運用で pending に戻す）
            await tRef.set(
              {
                billing: {
                  initialFee: {
                    status: "failed",
                    lastInvoiceId: inv.id,
                    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                  },
                },
              },
              { merge: true }
            );
          }
        }
      } catch (e) {
        console.warn("initial fee detection/write failed:", e);
      }

      // ★ ここで“本体サブスク”を取り直してローカルの取りこぼしを補正（incomplete→active など）
      if (type === "invoice.payment_succeeded" && inv.subscription) {
        try {
          const latestSub = await stripe.subscriptions.retrieve(inv.subscription as string);
          const latestStatus = latestSub.status;
          const overdue =
            latestStatus === "past_due" || latestStatus === "unpaid";
          const periodEndTs2 = tsFromSec(latestSub.current_period_end);
          const trialStartTs2 = tsFromSec(latestSub.trial_start);
          const trialEndTs2 = tsFromSec(latestSub.trial_end);

          const tRef = db.collection(uid).doc(tenantId);
          const curStatus =
            (await tRef.get()).data()?.subscription?.status as string | undefined;

          if (curStatus !== latestStatus) {
            await writeIndexAndOwner(uid, tenantId, {
              subscription: {
                status: latestStatus,
                stripeCustomerId: (latestSub.customer as string) ?? undefined,
                stripeSubscriptionId: latestSub.id,
                overdue,
                ...(periodEndTs2
                  ? {
                      currentPeriodEnd: periodEndTs2,
                      nextPaymentAt: periodEndTs2,
                    }
                  : {}),
                trial: {
                  status: latestStatus === "trialing" ? "trialing" : "none",
                  ...(trialStartTs2 ? { trialStart: trialStartTs2 } : {}),
                  ...(trialEndTs2 ? { trialEnd: trialEndTs2 } : {}),
                },
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
              },
            });
          }
        } catch (e) {
          console.warn("failed to refresh subscription after invoice success:", e);
        }
      }

      // ================= ここから：支払成功時に代理店へ送金（サブスク30%＋初期費用50%） =================
      try {
        if (type === "invoice.payment_succeeded" && inv.paid === true) {
          const amountPaid = (inv.amount_paid ?? 0) as number;
          const chargeId = (inv.charge as string | undefined) ?? undefined;
          const subscriptionId = inv.subscription as string | undefined;

          if (amountPaid > 0 && chargeId) {
            // subscription から tenantId / uid / transfer_group を取得（メタが入っていれば使う）
            let useTenantId: string | undefined = tenantId;
            let useUid: string | undefined = uid;
            let transferGroup: string | undefined = undefined;

            if (subscriptionId) {
              const subForTransfer = await stripe.subscriptions.retrieve(subscriptionId);
              useTenantId =
                (subForTransfer.metadata?.tenantId as string | undefined) ?? useTenantId;
              useUid =
                (subForTransfer.metadata?.uid as string | undefined) ?? useUid;
              transferGroup =
                (subForTransfer.metadata?.transfer_group as string | undefined) ?? undefined;
            }

            // 念のため uid が未確定なら index で補完
            if (!useUid) {
              const tRefIdx2 = await tenantRefByIndex(useTenantId!);
              useUid = tRefIdx2.parent!.id;
            }

            // 代理店の Connect アカウントID 取得
            const tRef2 = db.collection(useUid!).doc(useTenantId!);
            const tSnap2 = await tRef2.get();
            const agency = (tSnap2.data()?.agency ?? {}) as any;
            const linked = agency?.linked === true;
            const agentId =
              (agency?.agentId as string | undefined) ?? undefined;

            let agencyAccountId: string | undefined;
            if (linked && agentId) {
              const agentDoc = await db
                .collection("agencies")
                .doc(agentId)
                .get();
              agencyAccountId = (agentDoc.exists
                ? agentDoc.data()?.stripeAccountId
                : undefined) as string | undefined;
            }

            // --- ① 初期費用合計（Invoice の対象期間すべてを安全に走査） ---
            let initFeeTotal = 0;
            try {
              const { amount } = await pickInitialFeeLinesAll(
                stripe,
                inv,
                INITIAL_FEE_PRICE_ID
              );
              initFeeTotal = amount; // 最小単位（JPYなら円）
            } catch (e) {
              console.warn("pickInitialFeeLinesAll failed (proceeding with 0):", e);
            }

            // --- ② サブスク分と初期費用分に分解 ---
            const subPortion = Math.max(0, amountPaid - initFeeTotal);

            // 規定の配分率
            const transferSub  = Math.floor(subPortion   * 0.30); // サブスク30%
            const transferInit = Math.floor(initFeeTotal * 0.50); // 初期費用50%

            // 二重送金防止（invoice.id をキーにして既存確認）
            const alreadySub  = (tSnap2.data()?.subscriptionTransfers ?? {})[inv.id]?.id as (string | undefined);
            const alreadyInit = (tSnap2.data()?.initialFeeTransfers   ?? {})[inv.id]?.id as (string | undefined);

            if (agencyAccountId && (transferSub > 0 || transferInit > 0)) {
              const currency = (inv.currency ?? "jpy").toLowerCase();

              // --- ③ サブスク分 Transfer（従来の subscriptionTransfers を継続利用） ---
              if (transferSub > 0 && !alreadySub) {
                const idempotencyKeySub = `sub_transfer_${inv.id}_${useTenantId}_${agentId}`;
                const trSub = await stripe.transfers.create(
                  {
                    amount: transferSub,
                    currency,
                    destination: agencyAccountId,
                    ...(transferGroup ? { transfer_group: transferGroup } : {}),
                    // 残高 available まで Stripe 側で自動待機
                    source_transaction: chargeId,
                    metadata: {
                      purpose: "subscription_agency_commission",
                      tenantId: useTenantId!,
                      agentId: agentId ?? "",
                      invoiceId: inv.id,
                      subscriptionId: subscriptionId ?? "",
                      chargeId,
                    },
                  },
                  { idempotencyKey: idempotencyKeySub }
                );

                // Firestore 記録（従来のマップを維持）
                await tRef2.set(
                  {
                    subscriptionTransfers: {
                      [inv.id]: {
                        id: trSub.id,
                        amount: transferSub,
                        currency: currency.toUpperCase(),
                        destination: agencyAccountId,
                        transferGroup: transferGroup ?? null,
                        sourceCharge: chargeId,
                        created: admin.firestore.FieldValue.serverTimestamp(),
                      },
                    },
                  },
                  { merge: true }
                );
              }

              // --- ④ 初期費用分 Transfer（新しい initialFeeTransfers マップに格納） ---
              if (transferInit > 0 && !alreadyInit) {
                const idempotencyKeyInit = `init_transfer_${inv.id}_${useTenantId}_${agentId}`;
                const trInit = await stripe.transfers.create(
                  {
                    amount: transferInit,
                    currency,
                    destination: agencyAccountId,
                    ...(transferGroup ? { transfer_group: transferGroup } : {}),
                    source_transaction: chargeId,
                    metadata: {
                      purpose: "initial_fee_agency_commission",
                      tenantId: useTenantId!,
                      agentId: agentId ?? "",
                      invoiceId: inv.id,
                      subscriptionId: subscriptionId ?? "",
                      chargeId,
                    },
                  },
                  { idempotencyKey: idempotencyKeyInit }
                );

                // Firestore 記録（初期費用専用のマップ）
                await tRef2.set(
                  {
                    initialFeeTransfers: {
                      [inv.id]: {
                        id: trInit.id,
                        amount: transferInit,
                        currency: currency.toUpperCase(),
                        destination: agencyAccountId,
                        transferGroup: transferGroup ?? null,
                        sourceCharge: chargeId,
                        created: admin.firestore.FieldValue.serverTimestamp(),
                      },
                    },
                  },
                  { merge: true }
                );
              }
            }
          }
        }
      } catch (e) {
        console.error("Failed to create split transfers to agency:", e);
      }
      // ================= 追記ここまで =================

      // このテナントで見つかったのでループ終了
      foundUid = uid;
      foundTenantId = tenantId;
      break;
    }
  }

  // 請求書メール通知（既存）
  try {
    await sendInvoiceNotificationByCustomerId(customerId, inv, RESEND_API_KEY.value());
  } catch (e) {
    console.warn("[invoice mail] failed to send:", e);
  }

  await docRef.set({ handled: true }, { merge: true });
  res.sendStatus(200);
  return;
}



      /* ========== 5) Connect: アカウント状態 ========== */
if (type === "account.updated") {
  const acct = event.data.object as Stripe.Account;

  try {
    const tRef = await tenantRefByStripeAccount(acct.id);
    const reqs = acct.requirements;

    

    const connectStatus = deriveConnectStatus(acct);

    await tRef.set(
      {
        stripeAccountId: acct.id,
        connect: {
          charges_enabled: !!acct.charges_enabled,
          payouts_enabled: !!acct.payouts_enabled,
          details_submitted: !!acct.details_submitted,
          // 申請状況の全体像を保持（フロントでそのまま見せられるように）
          requirements: {
            currently_due: reqs!.currently_due ?? [],
            eventually_due: reqs!.eventually_due ?? [],
            past_due: reqs!.past_due ?? [],
            pending_verification: reqs!.pending_verification ?? [],
            disabled_reason: reqs!.disabled_reason ?? null,
          },
          status: connectStatus, // "active" | "action_required" | "pending" | "disabled"
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        // 現在の入金スケジュールを保存（毎月1日に固定している場合でも念のため保存）
        
        
      },
      { merge: true }
    );

    
  } catch (e) {
    console.warn("No tenant found in tenantStripeIndex for", acct.id, e);
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
          // インデックスにも反映
          await db.collection("tenantIndex").doc(tenantId).set(
            {
              billing: {
                initialFee: {
                  status: "paid",
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
    } catch (e) {
      console.error(e);
      res.sendStatus(500);
      return;
    }
  });

 

//=======================管理者追加============================


//* ===================== subscription ===================== */
export const createSubscriptionCheckout = functions
  .region("us-central1")
  .runWith({
    secrets: [
      "STRIPE_SECRET_KEY",
      "FRONTEND_BASE_URL",
      "INITIAL_FEE_PRICE_ID",
    ],
  })
  .https.onCall(async (data, context) => {
    const uid = context.auth?.uid;
    if (!uid) throw new functions.https.HttpsError("unauthenticated", "Sign-in required");

    const { tenantId, plan, email, name } = (data || {}) as {
      tenantId: string; plan: string; email?: string; name?: string;
    };
    if (!tenantId || !plan) {
      throw new functions.https.HttpsError("invalid-argument", "tenantId and plan are required.");
    }

    const STRIPE_KEY = process.env.STRIPE_SECRET_KEY!;
    const APP_BASE   = process.env.FRONTEND_BASE_URL!;
    const INITIAL_FEE_PRICE_ID = process.env.INITIAL_FEE_PRICE_ID!;
    const stripe = new Stripe(STRIPE_KEY, { apiVersion: "2023-10-16" });

    const TRIAL_DAYS = 30;

    const planDoc = await getPlanFromDb(plan);
    const purchaserEmail = email || (context.auth?.token?.email as string | undefined);
    const customerId = await ensureCustomer(uid, tenantId, purchaserEmail, name);

    // 進行中購読があればポータルへ
    const subs = await stripe.subscriptions.list({ customer: customerId, status: "all", limit: 20 });
    const hasOngoing = subs.data.some(s => ["active","trialing","past_due","unpaid"].includes(s.status));
    if (hasOngoing) {
      const portal = await stripe.billingPortal.sessions.create({
        customer: customerId,
        return_url: `${APP_BASE}#/settings?tenant=${encodeURIComponent(tenantId)}`
      });
      return { alreadySubscribed: true, portalUrl: portal.url };
    }

    // Firestore trial 判定（subscription.trial.status を優先）
    const tRef = tenantRefByUid(uid, tenantId);
    const tSnap = await tRef.get();
    const tData = tSnap.data() as any | undefined;
    const trialStatus: string =
      (tData?.subscription?.trial?.status as string | undefined) ??
      (tData?.trial?.status as string | undefined) ??
      (tData?.trialStatus as string | undefined) ?? "";
    const allowTrial = trialStatus !== "none";

    const successUrl = `${APP_BASE}#/store?tenantId=${tenantId}&event=initial_fee_paid`;
    const cancelUrl  = `${APP_BASE}#/store?tenantId=${tenantId}&event=initial_fee_paid`;

    // まだ初期費用が paid でなければ請求対象
    const needInitialFee = (tData?.billing?.initialFee?.status !== "paid");

    // line_items（recurring は必須）
    const lineItems: Stripe.Checkout.SessionCreateParams.LineItem[] = [
      { price: planDoc.stripePriceId, quantity: 1 },
    ];

    // ★ トライアルなし のときのみ、ここで初期費用(one-time)を同梱（即時）
    if (!allowTrial && needInitialFee) {
      lineItems.push({ price: INITIAL_FEE_PRICE_ID, quantity: 1 });
    }

    const transferGroup = `subtg_${tenantId}_${Date.now()}`; // ★追加
    // trial 設定
    const subscriptionData: Stripe.Checkout.SessionCreateParams.SubscriptionData =
      allowTrial
        ? { trial_period_days: TRIAL_DAYS, metadata: { tenantId, plan, uid, transfer_group: transferGroup } }
        : {  metadata: { tenantId, plan, uid, transfer_group: transferGroup } }; // 即時課金

    const session = await stripe.checkout.sessions.create({
      mode: "subscription",
      customer: customerId,
      line_items: lineItems,
      payment_method_collection: "always",
      allow_promotion_codes: true,
      metadata: { tenantId, plan, uid, trial_allowed: String(allowTrial) },
      subscription_data: subscriptionData,
      success_url: successUrl,
      cancel_url:  cancelUrl,
    });

    // UI ヒント（任意）
    if (needInitialFee) {
      await tRef.set(
        {
          billing: {
            initialFee: {
              // トライアルあり：Webhookで next invoice に載せるため pending メモ
              // トライアルなし：今の初回請求に同梱されるが UI 的には同じ表記でOK
              status: "pending_on_first_invoice",
              updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            },
          },
        },
        { merge: true }
      );
    }

    await upsertTenantIndex(uid, tenantId);
    return { url: session.url, mode: "subscription" };
  });



export const changeSubscriptionPlan = functions
  .region("us-central1")
  .runWith({ secrets: ["STRIPE_SECRET_KEY"] })
  .https.onCall(async (data, context) => {
    // ---- Auth ----
    const uid = context.auth?.uid;
    if (!uid) {
      throw new functions.https.HttpsError("unauthenticated", "Sign-in required");
    }

    // ---- Args ----
    const { subscriptionId, newPlan, tenantId, endTrialNow } = (data || {}) as {
      subscriptionId: string;
      newPlan: string;      // "A" | "B" | "C"
      tenantId?: string;    // 任意：テナント突き合わせ
      endTrialNow?: boolean; // 任意：トライアル中でも今すぐ課金開始したい場合 true
    };
    if (!subscriptionId || !newPlan) {
      throw new functions.https.HttpsError("invalid-argument", "subscriptionId and newPlan are required.");
    }

    // ---- Stripe ----
    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, { apiVersion: "2023-10-16" });

    // 新プラン解決（あなたの既存の Plan 定義に合わせて）
    const newPlanDoc = await getPlanFromDb(newPlan);

    // 現サブスク取得（プラットフォームオブジェクト）
    const sub = (await stripe.subscriptions.retrieve(subscriptionId, {
      expand: ["items.data.price.product"],
    })) as Stripe.Subscription;

    // （任意）tenantId が渡ってきたらテナントの保持する subId と突き合わせ
    if (tenantId) {
      const tenantRef = tenantRefByUid(uid, tenantId);
      const t = (await tenantRef.get()).data() as { subscription?: any } | undefined;
      const savedSubId = t?.subscription?.stripeSubscriptionId;
      if (savedSubId && savedSubId !== sub.id) {
        throw new functions.https.HttpsError("permission-denied", "Subscription does not match tenant.");
      }
    }

    // 更新対象 item（単一アイテム構成を想定。複数アイテムなら対象 price を特定して選ぶ）
    const item = sub.items.data[0];
    if (!item) {
      throw new functions.https.HttpsError("failed-precondition", "No subscription item found.");
    }

    // --- トライアルの取り扱いとアンカー ---
    const isTrialing = sub.status === "trialing";

    // デフォルト方針：
    // - トライアル中はアンカーを動かさない（= billing_cycle_anchor を指定しない）→ エラー回避
    // - 今すぐ課金開始したい場合のみ endTrialNow=true で trial を即終了し anchor=now
    // - トライアルでない場合は anchor=now で即日切替
    const updateParams: Stripe.SubscriptionUpdateParams = {
      items: [{ id: item.id, price: newPlanDoc.stripePriceId, quantity: item.quantity ?? 1 }],
      proration_behavior: "none",              // 差額調整なし
      cancel_at_period_end: false,             // 期末解約を抑止
      payment_behavior: "error_if_incomplete", // 未決済はエラー返却（フロントで SCA 等対応）
      metadata: { ...sub.metadata, plan: newPlan },
      expand: ["latest_invoice.payment_intent", "items.data.price.product"],
      // trial_from_plan は常に false（プラン側 trial を引き継がない）
      trial_from_plan: false,
    };

    if (isTrialing) {
      if (endTrialNow === true) {
        // トライアルを即終了 → その上で今をアンカーに
        updateParams.trial_end = "now";
        updateParams.billing_cycle_anchor = "now";
      } else {
        // トライアル継続 → 何も指定しない（Stripe が trial_end / anchor を保持）
        // 明示的に残したいなら trial_end=sub.trial_end を付けてもOK（ただし不要）
      }
    } else {
      // トライアルでない → 即日アンカー
      updateParams.billing_cycle_anchor = "now";
      // trial_end は付けない
    }

    // ---- Update ----
    const updated = await stripe.subscriptions.update(subscriptionId, updateParams);

    // ---- SCA/未決済 検知 ----
    const li = updated.latest_invoice as Stripe.Invoice | null;
    const pi = li?.payment_intent as Stripe.PaymentIntent | null;

    let requiresAction = false;
    let hostedInvoiceUrl: string | undefined = li?.hosted_invoice_url || undefined;
    let paymentIntentClientSecret: string | undefined = (pi?.client_secret as string | undefined) ?? undefined;
    let paymentIntentNextActionUrl: string | undefined;

    if (pi) {
      if (pi.status === "requires_action" || pi.status === "requires_confirmation") {
        requiresAction = true;
        paymentIntentNextActionUrl = (pi.next_action as any)?.redirect_to_url?.url;
      } else if (pi.status === "requires_payment_method") {
        requiresAction = true;
      }
    }

    // ---- Firestore 反映（plan を置換、その他は既存 mapSubToRecord に委譲）----
    if (tenantId) {
      const tenantRef = tenantRefByUid(uid, tenantId);
      const base = mapSubToRecord(updated); // { status, stripeCustomerId, stripeSubscriptionId, currentPeriodEnd,... } など
      await tenantRef.set(
        {
          subscription: {
            ...base,
            plan: newPlan, // plan を上書き
          },
        },
        { merge: true }
      );
    }

    return {
      ok: true,
      subscription: updated.id,
      requiresAction,
      hostedInvoiceUrl,
      paymentIntentClientSecret,
      paymentIntentNextActionUrl,
      status: updated.status,
      trialing: updated.status === "trialing",
    };
  });



export const cancelSubscription = functions
  .region("us-central1")
  .runWith({ secrets: ["STRIPE_SECRET_KEY"] })
  .https.onCall(async (data, context) => {
    const uid = context.auth?.uid;
    if (!uid) {
      throw new functions.https.HttpsError("unauthenticated", "Sign-in required");
    }

    const { tenantId, agreeNoTrialResume } = (data || {}) as {
      tenantId?: string;
      agreeNoTrialResume?: boolean;
    };
    if (!tenantId) {
      throw new functions.https.HttpsError("invalid-argument", "tenantId is required.");
    }
    if (!agreeNoTrialResume) {
      throw new functions.https.HttpsError("failed-precondition", "Must agree to no-trial-resume.");
    }

    const STRIPE_KEY = process.env.STRIPE_SECRET_KEY!;
    const stripe = new Stripe(STRIPE_KEY, { apiVersion: "2023-10-16" });

    const tenantRef = tenantRefByUid(uid, tenantId);
    const tSnap = await tenantRef.get();
    if (!tSnap.exists) {
      return { ok: false, code: "tenant_not_found" as const, message: "Tenant doc not found." };
    }
    const t = tSnap.data() as { subscription?: TenantSubscription } | undefined;

    const subId = t?.subscription?.stripeSubscriptionId;
    const customerId = t?.subscription?.stripeCustomerId;
    if (!subId || !customerId) {
      // そもそも登録なし or 情報不足
      await tenantRef.set(
        {
          subscription: {
            ...(t?.subscription ?? {}),
            status: "canceled",
            cancelAtPeriodEnd: false,
            plan: "none",
            cancelAt: null,
            canceledAt: Date.now(),
            updatedAt: admin.firestore.FieldValue.serverTimestamp?.() ?? new Date(),
            
          },
          status: "nonactive",
          
        },
        { merge: true }
        
      );
      return { ok: true, status: "no_subscription" as const };
    }

    try {
      const sub = await stripe.subscriptions.retrieve(subId);

      // すでに canceled
      if (sub.status === "canceled") {
        await tenantRef.set(
          {
            subscription: {
              ...(t?.subscription ?? {}),
              status: "canceled",
              cancelAtPeriodEnd: false,
              cancelAt: null,
              canceledAt: Date.now(),
              updatedAt: admin.firestore.FieldValue.serverTimestamp?.() ?? new Date(),
            },

          },
          { merge: true }
        );
        return { ok: true, status: "already_canceled" as const };
      }

      // すでに期末キャンセル予約あり
      if (sub.cancel_at_period_end) {
        await tenantRef.set(
          {
            subscription: {
              ...(t?.subscription ?? {}),
              status: sub.status,
              cancelAtPeriodEnd: true,
              cancelAt: sub.cancel_at ?? null,
              currentPeriodEnd: sub.current_period_end ?? null,
              updatedAt: admin.firestore.FieldValue.serverTimestamp?.() ?? new Date(),
            },
          },
          { merge: true }
        );
        return {
          ok: true,
          status: "already_cancel_at_period_end" as const,
          cancel_at: sub.cancel_at ?? null,
        };
      }

      // trialing は即時停止 / それ以外は期末停止
      if (sub.status === "trialing") {
        const canceled = await stripe.subscriptions.cancel(sub.id);
        await tenantRef.set(
          {
            subscription: {
              ...(t?.subscription ?? {}),
              status: canceled.status, // "canceled"
              cancelAtPeriodEnd: false,
              cancelAt: null,
              canceledAt: Date.now(),
              currentPeriodEnd: canceled.current_period_end ?? null,
              endedAt: canceled.ended_at ?? null,
              updatedAt: admin.firestore.FieldValue.serverTimestamp?.() ?? new Date(),
              trial: {
            trialEnd: Date.now(),
            status: "none"
          }
            },
            
          },
          { merge: true }
        );
        return { ok: true, status: "canceled_now" as const };
      } else {
        const updated = await stripe.subscriptions.update(sub.id, {
          cancel_at_period_end: true,
        });
        await tenantRef.set(
          {
            subscription: {
              ...(t?.subscription ?? {}),
              status: updated.status, // "active" 等
              cancelAtPeriodEnd: true,
              cancelAt: updated.cancel_at ?? null, // epoch seconds
              currentPeriodEnd: updated.current_period_end ?? null,
              updatedAt: admin.firestore.FieldValue.serverTimestamp?.() ?? new Date(),
            },
          },
          { merge: true }
        );
        return {
          ok: true,
          status: "cancel_at_period_end" as const,
          cancel_at: updated.cancel_at ?? null,
        };
      }
    } catch (err: any) {
      // Stripe 例外を前面に
      const reqId = err?.raw?.requestId || err?.raw?.request_id || err?.requestId;
      console.error("cancelSubscription error", { err, requestId: reqId });
      return {
        ok: false,
        code: "stripe_error" as const,
        message: err?.message ?? "Stripe error",
        requestId: reqId ?? null,
      };
    }
  });


export const getUpcomingInvoiceByCustomer = onCall(
  {
    region: "us-central1",
    secrets: ["STRIPE_SECRET_KEY"],
  },
  async (req) => {
    if (!req.auth) throw new HttpsError("unauthenticated", "Sign-in required");
    const callerUid = req.auth.uid;

    const {
      customerId,
      subscriptionId,          // 任意：指定なければ自動解決
      newPriceId,              // 任意：プラン変更プレビュー

    } = (req.data || {}) as {
      customerId?: string;
      subscriptionId?: string;
      newPriceId?: string;
    };

    if (!customerId) {
      throw new HttpsError("invalid-argument", "customerId is required");
    }

    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: "2023-10-16",
    });

    // --- 購読IDが無ければアクティブ系から自動解決 ---
    let subId = subscriptionId;
    if (!subId) {
      const subs = await stripe.subscriptions.list({
        customer: customerId,
        status: "all",
        limit: 20,
      });
      const pick = subs.data.find((s) =>
        ["active", "trialing", "past_due", "unpaid"].includes(s.status)
      );
      if (!pick) {
        // サブスクが無い＝upcomingが無い可能性が高い（都度課金のみなど）
        // 以降は subscription を付けずに upcoming を試す（都度があれば返る）
      } else {
        subId = pick.id;
      }
    }

    // --- upcoming パラメータ ---
    const params: Stripe.InvoiceRetrieveUpcomingParams = {
      customer: customerId,
      ...(subId ? { subscription: subId } : {}),
      expand: ["lines.data.price.product"],
    };

    // 価格変更プレビュー
    if (newPriceId) {
      if (!subId) {
        return {
          ok: false,
          code: "no_subscription",
          message: "Active subscription not found for preview.",
        };
      }
      const sub = await stripe.subscriptions.retrieve(subId);
      const item = sub.items.data[0];
      if (!item?.id) {
        return {
          ok: false,
          code: "no_subscription_item",
          message: "Subscription item not found.",
        };
      }
      (params as any).subscription_items = [
        { id: item.id, price: newPriceId, quantity: item.quantity ?? 1 },
      ];
      
    }

    try {
      const upcoming = await stripe.invoices.retrieveUpcoming(params);

      const lines = upcoming.lines.data.map((l) => {
        const price = l.price ?? undefined;
        const product = (price?.product as Stripe.Product | null) ?? null;
        return {
          id: l.id,
          description: l.description ?? null,
          quantity: l.quantity ?? 1,
          unit_amount: price?.unit_amount ?? null,
          amount: l.amount ?? null,
          currency: l.currency ?? upcoming.currency,
          proration: !!l.proration,
          price: {
            id: price?.id ?? null,
            nickname: price?.nickname ?? null,
            unit_amount: price?.unit_amount ?? null,
            recurring:
              price && "recurring" in price ? price.recurring ?? null : null,
          },
          product: product ? { id: product.id, name: product.name } : null,
        };
      });

      return {
        ok: true,
        
        customerId,
        subscriptionId: subId ?? null,
        currency: upcoming.currency,
        amount_due: upcoming.amount_due,
        amount_remaining: upcoming.amount_remaining,
        subtotal: upcoming.subtotal,
        tax: upcoming.tax,
        total: upcoming.total,
        next_payment_attempt: upcoming.next_payment_attempt ?? null,
        period_start: upcoming.period_start ?? null,
        period_end: upcoming.period_end ?? null,
        has_proration: lines.some((l) => l.proration),
        lines,
      };
    } catch (err: any) {
      const code: string | undefined = err?.code || err?.raw?.code;
      if (code === "invoice_upcoming_none") {
        return { ok: true, none: true, customerId, subscriptionId: subId ?? null, lines: [] };
      }
      const requestId =
        err?.raw?.requestId || err?.raw?.request_id || err?.requestId || null;
      console.error("getUpcomingInvoiceByCustomer error", { err, requestId });
      throw new HttpsError(
        "internal",
        err?.message || "Stripe error",
        { requestId, code: err?.code || null }
      );
    }
  }
);

export const listConnectPayouts = functions
  .region("us-central1")
  .runWith({ secrets: ["STRIPE_SECRET_KEY"] })
  .https.onCall(async (data, context) => {
    const uid = context.auth?.uid;
    if (!uid) throw new functions.https.HttpsError("unauthenticated", "Sign-in required");

    const { tenantId, limit = 20 } = (data || {}) as { tenantId?: string; limit?: number };
    if (!tenantId) throw new functions.https.HttpsError("invalid-argument", "tenantId required");

    // Firestore からテナントの接続アカウントIDを解決
    const tRef = tenantRefByUid(uid, tenantId);
    const tDoc = await tRef.get();
    if (!tDoc.exists) throw new functions.https.HttpsError("not-found", "Tenant not found");

    const acctId = tDoc.data()?.stripeAccountId as string | undefined;
    if (!acctId) throw new functions.https.HttpsError("failed-precondition", "Tenant not connected to Stripe");

    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, { apiVersion: "2023-10-16" });

    // 接続アカウント側の入金一覧
    const payouts = await stripe.payouts.list(
      { limit: Math.max(1, Math.min(100, Number(limit) || 20)) },
      { stripeAccount: acctId }
    );

    // 返却：UI で使う分だけ整形
    return {
      payouts: payouts.data.map(p => ({
        id: p.id,
        amount: p.amount,
        currency: p.currency,
        arrival_date: p.arrival_date, // epoch sec
        created: p.created,
        status: p.status,             // paid / in_transit / pending / canceled / failed
        method: p.method,             // standard / instant
        type: p.type,                 // bank_account, card, etc
        statement_descriptor: p.statement_descriptor ?? null,
      })),
    };
  });

  export const getConnectPayoutDetails = functions
  .region("us-central1")
  .runWith({ secrets: ["STRIPE_SECRET_KEY"] })
  .https.onCall(async (data, context) => {
    const uid = context.auth?.uid;
    if (!uid) throw new functions.https.HttpsError("unauthenticated", "Sign-in required");

    const { tenantId, payoutId } = (data || {}) as { tenantId?: string; payoutId?: string };
    if (!tenantId || !payoutId) {
      throw new functions.https.HttpsError("invalid-argument", "tenantId and payoutId required");
    }

    const tRef = tenantRefByUid(uid, tenantId);
    const tDoc = await tRef.get();
    if (!tDoc.exists) throw new functions.https.HttpsError("not-found", "Tenant not found");

    const acctId = tDoc.data()?.stripeAccountId as string | undefined;
    if (!acctId) throw new functions.https.HttpsError("failed-precondition", "Tenant not connected to Stripe");

    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, { apiVersion: "2023-10-16" });

    // 入金本体
    const payout = await stripe.payouts.retrieve(payoutId, { stripeAccount: acctId });

    // この入金に含まれる明細（売上・返金・手数料など）を取得
    // balance_transactions.list は payout フィルタで絞れます
    const txns = await stripe.balanceTransactions.list(
      { payout: payoutId, limit: 100 },
      { stripeAccount: acctId }
    );

    // 合計の確認（サマリ）
    const gross = txns.data.reduce((s, t) => s + (t.amount ?? 0), 0);
    const fees  = txns.data.reduce((s, t) => s + (t.fee ?? 0), 0);
    const net   = txns.data.reduce((s, t) => s + (t.net ?? 0), 0);

    return {
      payout: {
        id: payout.id,
        amount: payout.amount,
        currency: payout.currency,
        arrival_date: payout.arrival_date,
        created: payout.created,
        status: payout.status,
        method: payout.method,
        type: payout.type,
        statement_descriptor: payout.statement_descriptor ?? null,
      },
      summary: { gross, fees, net, currency: payout.currency },
      lines: txns.data.map(t => ({
        id: t.id,
        type: t.type,                 // charge/refund/adjustment/transfer/application_fee…
        amount: t.amount,
        fee: t.fee,
        net: t.net,
        currency: t.currency,
        description: t.description ?? null,
        available_on: t.available_on,
        created: t.created,
        source: typeof t.source === "string" ? t.source : (t.source as any)?.id ?? null,
      })),
    };
  });



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
    if (!customerId) return { invoices: [], one_time: [], history: [] };

    const limitClamped = Math.min(Math.max(limit ?? 12, 1), 50);

    // 1) expand は price まで（product まで広げると階層オーバー）
    const invoicesPromise = stripe.invoices.list({
      customer: customerId,
      limit: limitClamped,
      expand: ["data.lines.data.price"], // ← ここを浅く
    });

    // 2) いわゆる都度払い（Checkout mode=payment 等）。invoice 付きは除外
    const paymentIntentsPromise = stripe.paymentIntents.list({
      customer: customerId,
      limit: limitClamped,
      expand: ["data.latest_charge"],
    });

    const [invResp, piResp] = await Promise.all([invoicesPromise, paymentIntentsPromise]);

    // --- 任意: product 名が欲しい場合は個別に取得（重複排除） ---
    const productIds = new Set<string>();
    for (const inv of invResp.data) {
      for (const li of inv.lines?.data ?? []) {
        const price = li.price as Stripe.Price | null;
        if (!price) continue;
        const p = price.product as string | Stripe.Product | null;
        const productId = typeof p === "string" ? p : p?.id;
        if (productId) productIds.add(productId);
      }
    }

    const productsById: Record<string, Stripe.Product> = {};
    if (productIds.size > 0) {
      // API に ids フィルタは無いので retrieve をまとめて実行
      // 数が多い時は上限を決める（例: 25）
      const ids = Array.from(productIds).slice(0, 25);
      const prods = await Promise.all(ids.map((id) => stripe.products.retrieve(id)));
      for (const p of prods) productsById[p.id] = p;
    }

    const invoices = invResp.data.map((inv) => {
      // 表示用に「最初の行」の price/product を軽く展開（必要に応じて拡張）
      const firstLine = inv.lines?.data?.[0];
      const price = (firstLine?.price as Stripe.Price | null) ?? null;
      const productId =
        price && price.product
          ? (typeof price.product === "string" ? price.product : price.product.id)
          : null;

      return {
        kind: "invoice" as const,
        id: inv.id,
        number: inv.number,
        amount_due: inv.amount_due,
        amount_paid: inv.amount_paid,
        currency: inv.currency,
        status: inv.status,
        hosted_invoice_url: inv.hosted_invoice_url ?? null,
        invoice_pdf: inv.invoice_pdf ?? null,
        description: firstLine?.description ?? inv.description ?? null,
        period_start: firstLine?.period?.start ?? inv.created,
        period_end: firstLine?.period?.end ?? inv.created,
        created: inv.created,
        // 追加情報（あってもなくてもOK）
        first_line_price_id: price?.id ?? null,
        first_line_product_id: productId,
        first_line_product_name: productId ? productsById[productId]?.name ?? null : null,
      };
    });

    const oneTime = piResp.data
      .filter((pi) => !pi.invoice) // 請求書に紐づく支払いは重複するので除外
      .map((pi) => {
        const charge = (pi.latest_charge as Stripe.Charge | null) ?? null;
        return {
          kind: "payment_intent" as const,
          id: pi.id,
          amount: pi.amount,
          currency: pi.currency,
          status: pi.status,
          description: pi.description ?? null,
          receipt_url: charge?.receipt_url ?? null,
          charge_id: charge?.id ?? null,
          created: pi.created,
        };
      });

    // タイムライン（UIで「すべて」タブ用）
    const history = [
      ...invoices.map((x) => ({
        type: "invoice" as const,
        id: x.id,
        amount: x.amount_paid ?? x.amount_due,
        currency: x.currency,
        status: x.status,
        url: x.hosted_invoice_url ?? x.invoice_pdf ?? null,
        description: x.description,
        created: x.created,
      })),
      ...oneTime.map((x) => ({
        type: "payment_intent" as const,
        id: x.id,
        amount: x.amount,
        currency: x.currency,
        status: x.status,
        url: x.receipt_url,
        description: x.description,
        created: x.created,
      })),
    ].sort((a, b) => b.created - a.created);

    return { invoices, one_time: oneTime, history };
  });

export const upsertAgencyConnectedAccount = onCall(
  { region: "us-central1", memory: "256MiB", secrets: ["STRIPE_SECRET_KEY", "FRONTEND_BASE_URL"] },
  async (req) => {
    if (!req.auth) throw new HttpsError("unauthenticated", "auth required");
    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, { apiVersion: "2023-10-16" });

    const agentId = (req.data?.agentId as string | undefined)?.trim();
    const form = (req.data?.account || {}) as any;
    if (!agentId) throw new HttpsError("invalid-argument", "agentId required");

    
    const aRef = db.collection("agencies").doc(agentId);
    const aDoc = await aRef.get();
    if (!aDoc.exists) throw new HttpsError("not-found", "agency not found");

    const data = aDoc.data() || {};
    let acctId = (data.stripeAccountId as string | undefined) ?? undefined;

    // 毎月1日固定
    const FORCE_MONTHLY_FIRST: Stripe.AccountUpdateParams.Settings.Payouts.Schedule = {
      interval: "monthly",
      monthly_anchor: 1,
    };

    const country: string = form.country || "JP";

    // 作成
    if (!acctId) {
      const created = await stripe.accounts.create({
        type: "custom",
        country,
        email: form.email,
        business_type: form.businessType || "individual",
        capabilities: { card_payments: { requested: true }, transfers: { requested: true } },
        settings: { payouts: { schedule: FORCE_MONTHLY_FIRST } },
      });
      acctId = created.id;

      await aRef.set(
        {
          stripeAccountId: acctId,
          connect: {
            charges_enabled: created.charges_enabled,
            payouts_enabled: created.payouts_enabled,
          },
          
        },
        { merge: true }
      );
    }

    // 更新
    const upd: Stripe.AccountUpdateParams = {};
    if (form.businessType) upd.business_type = form.businessType;
    if (form.businessProfile) upd.business_profile = form.businessProfile;
    if (form.individual) upd.individual = form.individual;
    if (form.company) upd.company = form.company;
    if (form.bankAccountToken) upd.external_account = form.bankAccountToken;

    if (form.tosAccepted) {
      upd.tos_acceptance = {
        date: Math.floor(Date.now() / 1000),
        ip: (req.rawRequest.headers["x-forwarded-for"] as string)?.split(",")[0] || req.rawRequest.ip,
        user_agent: req.rawRequest.get("user-agent") || undefined,
      };
    }

    upd.settings = {
      ...(upd.settings || {}),
      payouts: { ...((upd.settings?.payouts as any) || {}), schedule: FORCE_MONTHLY_FIRST },
    };

    const updated = await stripe.accounts.update(acctId!, upd);

    // 追加情報が必要ならオンボーディング URL
    const due = updated.requirements?.currently_due ?? [];
    const pastDue = updated.requirements?.past_due ?? [];
    const needsHosted = due.length > 0 || pastDue.length > 0;

    let onboardingUrl: string | undefined;
    if (needsHosted) {
      const BASE = process.env.FRONTEND_BASE_URL!;
      const link = await stripe.accountLinks.create({
        account: acctId!,
        type: "account_onboarding",
        refresh_url: `${BASE}#/agents/${encodeURIComponent(agentId)}?onboarding=refresh`,
        return_url: `${BASE}#/agents/${encodeURIComponent(agentId)}?onboarding=return`,
      });
      onboardingUrl = link.url;
    }

    // Firestore 反映
    await aRef.set(
      {
        connect: {
          charges_enabled: updated.charges_enabled,
          payouts_enabled: updated.payouts_enabled,
          requirements: updated.requirements || null,
        },
        payoutSchedule: { interval: "monthly", monthly_anchor: 1 },
        
      },
      { merge: true }
    );

    return {
      accountId: acctId,
      chargesEnabled: updated.charges_enabled,
      payoutsEnabled: updated.payouts_enabled,
      onboardingUrl,
      payoutSchedule: { interval: "monthly", monthly_anchor: 1 },
      due,
    };
  }
);


/* ===================== Connect: Custom（uid/{tenantId}） ===================== */
export const upsertConnectedAccount = onCall(
  {
    region: "us-central1",
    memory: "256MiB",
    cors: ALLOWED_ORIGINS,
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

    const data = tDoc.data() || {};
    const members: string[] = (data.members ?? data.memberUids ?? []) as string[];
    if (!Array.isArray(members) || !members.includes(uid)) {
      throw new HttpsError("permission-denied", "not a tenant member");
    }

    // ★★★ ここから：入金スケジュールは常に「毎月1日」に固定 ★★★
    // Stripe の型: Stripe.AccountUpdateParams.Settings.Payouts.Schedule
    const FORCE_MONTHLY_FIRST: Stripe.AccountUpdateParams.Settings.Payouts.Schedule = {
      interval: "monthly",
      monthly_anchor: 1,
      // delay_days は固定化しない（必要なら 'minimum' などに固定可）
      // delay_days: "minimum",
    };
    // ★★★ ここまで固定設定 ★★★

    const stripe = stripeClient();

    let acctId: string | undefined = data.stripeAccountId as string | undefined;
    const country: string = form.country || "JP";

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
        // ★ 作成時点で「毎月1日」を強制
        settings: { payouts: { schedule: FORCE_MONTHLY_FIRST } },
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

      await upsertTenantIndex(uid, tenantId, acctId);
    }

    // 更新パラメータ（フォームは受けるがスケジュールは強制上書き）
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

    // ★ 更新時も必ず「毎月1日」で上書き
    upd.settings = {
      ...(upd.settings || {}),
      payouts: {
        ...((upd.settings?.payouts as any) || {}),
        schedule: FORCE_MONTHLY_FIRST,
      },
    };

    const updated = await stripe.accounts.update(acctId!, upd);

    // onboarding 必要判定
    const due = updated.requirements?.currently_due ?? [];
    const pastDue = updated.requirements?.past_due ?? [];
    const needsHosted = due.length > 0 || pastDue.length > 0;

    let onboardingUrl: string | undefined;
    if (needsHosted) {
      const BASE = process.env.FRONTEND_BASE_URL!;
      const link = await stripe.accountLinks.create({
        account: acctId!,
        type: "account_onboarding",
        refresh_url: `${BASE}#/store?tenantId=${encodeURIComponent(tenantId)}&event=initial_fee_canceled`,
        return_url: `${BASE}#/store?tenantId=${encodeURIComponent(tenantId)}&event=initial_fee_paid`,
      });
      onboardingUrl = link.url;
    }

    // Firestore へ最新状態を保存（現在の payoutSchedule も保持）
    await tRef.set(
      {
        connect: {
          charges_enabled: updated.charges_enabled,
          payouts_enabled: updated.payouts_enabled,
          requirements: updated.requirements || null,
        },
        // ★ 返ってきた値ではなく、方針として固定の値を保存
        payoutSchedule: {
          interval: "monthly",
          monthly_anchor: 1,
        },
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );

    await upsertTenantIndex(uid, tenantId, acctId);

    return {
      accountId: acctId,
      chargesEnabled: updated.charges_enabled,
      payoutsEnabled: updated.payouts_enabled,
      due,
      onboardingUrl,
      // フロントにも固定値を返す
      payoutSchedule: {
        interval: "monthly",
        monthly_anchor: 1,
      },
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
    if (!uid) throw new functions.https.HttpsError("unauthenticated", "Sign-in required.");

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

    const successUrl = `${APP_BASE}#/store?tenantId=${tenantId}&event=initial_fee_paid`;
    const cancelUrl  = `${APP_BASE}#/store?tenantId=${tenantId}&event=initial_fee_canceled`;

    // ★ 後続の transfer と結びつけるための transfer_group を付与
    const transferGroup = `initial_fee:${tenantId}`;

    const session = await stripe.checkout.sessions.create({
      mode: "payment",
      customer: customerId,
      line_items: [{ price: priceId, quantity: 1 }],
      client_reference_id: tenantId,
      payment_intent_data: {
        metadata: { tenantId, kind: "initial_fee", uid },
        transfer_group: transferGroup,            // ← 追加
      },
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



 export const createCustomerPortalSession = onCall(
  {
    secrets: [STRIPE_SECRET_KEY, FRONTEND_BASE_URL],
    // region/memory は setGlobalOptions で指定済み（ここに書いてもOK）
  },
  async (req) => {
    if (!req.auth) throw new HttpsError("unauthenticated", "auth required");

    const APP_BASE = FRONTEND_BASE_URL.value();
    const uid = req.auth.uid;
    const tenantId = (req.data?.tenantId as string | undefined)?.trim();
    if (!tenantId) throw new HttpsError("invalid-argument", "tenantId required");

    const email = (req.auth.token.email as string | undefined) ?? undefined;
    const name = (req.auth.token.name as string | undefined) ?? undefined;
    const customerId = await ensureCustomer(uid, tenantId, email, name);

    const stripe = new Stripe(STRIPE_SECRET_KEY.value(), { apiVersion: "2023-10-16" });


    

    const returnUrl = `${APP_BASE}#/account?tenantId=${encodeURIComponent(tenantId)}`;
    const session = await stripe.billingPortal.sessions.create({
      customer: customerId,
      return_url: returnUrl,
    });

    return { url: session.url };
  }
);

export const createConnectAccountLink = onCall(
  {
    secrets: [STRIPE_SECRET_KEY, FRONTEND_BASE_URL],
  },
  async (req) => {
    if (!req.auth) throw new HttpsError("unauthenticated", "auth required");

    const APP_BASE = FRONTEND_BASE_URL.value();
    const uid = req.auth.uid;
    const tenantId = (req.data?.tenantId as string | undefined)?.trim();
    if (!tenantId) throw new HttpsError("invalid-argument", "tenantId required");

    const tRef = db.collection(uid).doc(tenantId);
    const tSnap = await tRef.get();
    if (!tSnap.exists) throw new HttpsError("not-found", "tenant not found");

    const stripeAccountId = (tSnap.data()?.stripeAccountId as string | undefined) ?? undefined;
    if (!stripeAccountId) throw new HttpsError("failed-precondition", "Connect account not created");

    const stripe = new Stripe(STRIPE_SECRET_KEY.value(), { apiVersion: "2023-10-16" });

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
  }
);