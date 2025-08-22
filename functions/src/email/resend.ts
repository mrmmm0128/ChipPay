import * as admin from 'firebase-admin';
import { Resend } from 'resend';
import { defineSecret } from 'firebase-functions/params';

const RESEND_API_KEY = defineSecret('RESEND_API_KEY');

/**
 * チップ確定ドキュメントを読み、宛先と本文を組み立てて Resend で送る。
 * - スタッフ宛チップ: staff の email を優先
 * - 店舗宛チップ: tenants/{tenantId}.notificationEmails[] を優先（なければ無通）
 */
export async function sendTipNotification(tenantId: string, tipId: string) {
  const db = admin.firestore();
  const tipRef = db.collection('tenants').doc(tenantId).collection('tips').doc(tipId);
  const tipSnap = await tipRef.get();
  if (!tipSnap.exists) return;

  const tip = tipSnap.data()!;
  const amount: number = (tip.amount as number) ?? 0;
  const currency = (tip.currency as string)?.toUpperCase() ?? 'JPY';
  const recipient: any = tip.recipient ?? {};
  const isEmployee = recipient.type === 'employee' || !!tip.employeeId;

  // ---- 宛先を決定 ----
  const to: string[] = [];

  if (isEmployee) {
    const empId = (tip.employeeId as string) ?? recipient.employeeId;
    if (empId) {
      const empSnap = await db.collection('tenants').doc(tenantId).collection('employees').doc(empId).get();
      const empEmail = empSnap.get('email') as string | undefined;
      if (empEmail) to.push(empEmail);
    }
  } else {
    const tenSnap = await db.collection('tenants').doc(tenantId).get();
    const notify = tenSnap.get('notificationEmails') as string[] | undefined;
    if (notify?.length) to.push(...notify);
  }

  // フォールバック（ドキュメントに直接入っている場合）
  if (to.length === 0) {
    const fallback =
      (tip.employeeEmail as string | undefined) ||
      (recipient.employeeEmail as string | undefined) ||
      (tip.storeEmail as string | undefined);
    if (fallback) to.push(fallback);
  }

  if (to.length === 0) {
    console.warn('[tip mail] no recipient found', { tenantId, tipId });
    return;
  }

  // ---- 表示用情報 ----
  const isJPY = currency === 'JPY';
  const money = isJPY ? `¥${amount.toLocaleString('ja-JP')}` : `${amount} ${currency}`;
  const name = isEmployee
    ? (tip.employeeName ?? recipient.employeeName ?? 'スタッフ')
    : (tip.storeName ?? recipient.storeName ?? '店舗');
  const memo = (tip.memo as string) || '';
  const createdAt: Date = tip.createdAt?.toDate?.() ?? new Date();

  const subject = isEmployee ? `チップを受け取りました: ${money}` : `店舗宛のチップ: ${money}`;
  const text = [
    `受取先: ${name}`,
    `金額: ${money}`,
    memo ? `メモ: ${memo}` : '',
    `日時: ${createdAt.toLocaleString('ja-JP')}`
  ].filter(Boolean).join('\n');

  const html = `
  <div style="font-family: system-ui, -apple-system, Segoe UI, Roboto, Helvetica, Arial; line-height:1.6; color:#111">
    <h2 style="margin:0 0 12px">🎉 ${subject}</h2>
    <p style="margin:0 0 6px">受取先：<strong>${escapeHtml(name)}</strong></p>
    <p style="margin:0 0 6px">金額：<strong>${escapeHtml(money)}</strong></p>
    ${memo ? `<p style="margin:0 0 6px">メモ：${escapeHtml(memo)}</p>` : ''}
    <p style="margin:0 0 6px">日時：${createdAt.toLocaleString('ja-JP')}</p>
  </div>`;

  // ---- Resend で送信 ----
  const resend = new Resend(RESEND_API_KEY.value());
  await resend.emails.send({
    from: 'YourPay 通知 <sendtip_app@appfromkomeda.jp>', // ← Resendで認証済みの差出人に置き換え
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
  return s.replace(/[&<>'"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;' }[c]!));
}
