import * as functions from 'firebase-functions';
import * as admin from 'firebase-admin';

export const setUserClaims = functions.https.onCall(async (data, ctx) => {
  // ここは superadmin のみ許可するなどの認可チェックを入れる
  if (!ctx.auth) throw new functions.https.HttpsError('unauthenticated', 'auth required');
  const callerClaims = (ctx.auth.token as any) || {};
  if (callerClaims.role !== 'superadmin') {
    throw new functions.https.HttpsError('permission-denied', 'superadmin only');
  }

  const { uid, tenantId, role } = data as { uid: string; tenantId: string; role: string };
  await admin.auth().setCustomUserClaims(uid, { tenantId, role });
  return { ok: true };
});

