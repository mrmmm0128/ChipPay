"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.sendTipNotification = sendTipNotification;
const admin_1 = require("./admin");
const db = admin_1.admin.firestore();
const resend_1 = require("resend");
const params_1 = require("firebase-functions/params");
const RESEND_API_KEY = (0, params_1.defineSecret)('RESEND_API_KEY');
/**
 * チップ確定ドキュメントを読み、宛先と本文を組み立てて Resend で送る。
 * - スタッフ宛チップ: staff の email を優先
 * - 店舗宛チップ: tenants/{tenantId}.notificationEmails[] を優先（なければ無通）
 */
async function sendTipNotification(tenantId, tipId) {
    const db = admin_1.admin.firestore();
    const tipRef = db.collection('tenants').doc(tenantId).collection('tips').doc(tipId);
    const tipSnap = await tipRef.get();
    if (!tipSnap.exists)
        return;
    const tip = tipSnap.data();
    const amount = tip.amount ?? 0;
    const currency = tip.currency?.toUpperCase() ?? 'JPY';
    const recipient = tip.recipient ?? {};
    const isEmployee = recipient.type === 'employee' || !!tip.employeeId;
    // ---- 宛先を決定 ----
    const to = [];
    if (isEmployee) {
        const empId = tip.employeeId ?? recipient.employeeId;
        if (empId) {
            const empSnap = await db.collection('tenants').doc(tenantId).collection('employees').doc(empId).get();
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
    // フォールバック（ドキュメントに直接入っている場合）
    if (to.length === 0) {
        const fallback = tip.employeeEmail ||
            recipient.employeeEmail ||
            tip.storeEmail;
        if (fallback)
            to.push(fallback);
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
    const memo = tip.memo || '';
    const createdAt = tip.createdAt?.toDate?.() ?? new Date();
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
    const resend = new resend_1.Resend(RESEND_API_KEY.value());
    await resend.emails.send({
        from: 'YourPay 通知 <sendtip_app@appfromkomeda.jp>', // ← Resendで認証済みの差出人に置き換え
        to,
        subject,
        text,
        html,
    });
    await tipRef.set({ notification: { emailedAt: admin_1.admin.firestore.FieldValue.serverTimestamp(), to } }, { merge: true });
}
function escapeHtml(s) {
    return s.replace(/[&<>'"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;' }[c]));
}
