// admin.ts
import * as admin from 'firebase-admin';
if (!admin.apps.length) {
  admin.initializeApp(); // 1回だけ
}
export { admin };