import 'package:cloud_firestore/cloud_firestore.dart';

Future<String?> fetchUidByTenantIndex(String tenantId) async {
  try {
    final snap = await FirebaseFirestore.instance
        .collection('tenantIndex')
        .doc(tenantId)
        .get();
    return snap.data()?['uid'] as String?;
  } catch (_) {
    return null;
  }
}
