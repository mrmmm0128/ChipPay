import 'package:cloud_firestore/cloud_firestore.dart';

/// -------- 内部共通: 正規化 & 取り出し --------
String _norm(Object? v) => (v is String)
    ? v.trim().toLowerCase().replaceAll(RegExp(r'[\s_-]'), '')
    : '';

/// ドキュメント内の “プラン” らしき文字列を最初に見つかった場所から取り出す
String? _extractPlanRaw(Map<String, dynamic>? data) {
  if (data == null) return null;
  final sub = (data['subscription'] as Map?)?.cast<String, dynamic>();

  // 候補キー（上から順に優先）
  final candidates = <Object?>[
    sub?['plan'],
    sub?['tier'],
    data['plan'],
    data['tier'],
    data['productPlan'],
    data['skuPlan'],
  ];

  for (final v in candidates) {
    final s = (v is String) ? v.trim() : null;
    if (s != null && s.isNotEmpty) return s;
  }
  return null;
}

/// A/B/C などに揃える（わからなければ元の文字列をそのまま返す）
String _canonicalizePlan(String raw) {
  final n = _norm(raw);

  // 代表的な別名を吸収
  const aAliases = {'a', 'aplan', 'plana', 'free', 'basic'};
  const bAliases = {'b', 'bplan', 'planb', 'pro', 'standard'};
  const cAliases = {'c', 'cplan', 'planc', 'premium'};

  if (aAliases.contains(n)) return 'A';
  if (bAliases.contains(n)) return 'B';
  if (cAliases.contains(n)) return 'C';

  // A/B/C 以外の表記は見た目だけ整えて返す
  return raw.trim();
}

/// -------- 公開API: “プラン文字列” を取得 --------

/// 0) Map から直接（テストや既読データの整形に）
String? planStringFromData(
  Map<String, dynamic>? data, {
  bool canonical = true,
}) {
  final raw = _extractPlanRaw(data);
  if (raw == null || raw.isEmpty) return null;
  return canonical ? _canonicalizePlan(raw) : raw;
}

/// 1) 単発取得（DocumentRef 指定）
Future<String> fetchPlanString(
  DocumentReference<Map<String, dynamic>> tenantRef, {
  String defaultValue = 'UNKNOWN',
  bool canonical = true,
}) async {
  final snap = await tenantRef.get();
  if (!snap.exists) return defaultValue;
  return planStringFromData(snap.data(), canonical: canonical) ?? defaultValue;
}

/// 2) 監視（サブスク変更に追従）
Stream<String> watchPlanString(
  DocumentReference<Map<String, dynamic>> tenantRef, {
  String defaultValue = 'UNKNOWN',
  bool canonical = true,
}) {
  return tenantRef.snapshots().map((snap) {
    return planStringFromData(snap.data(), canonical: canonical) ??
        defaultValue;
  });
}

/// 3) uid / tenantId から直接
Future<String> fetchPlanStringById(
  String uid,
  String tenantId, {
  String defaultValue = 'UNKNOWN',
  bool canonical = true,
}) {
  final ref = FirebaseFirestore.instance.collection(uid).doc(tenantId);
  return fetchPlanString(ref, defaultValue: defaultValue, canonical: canonical);
}

/// （既存互換）Cプラン判定
bool _isC(Object? plan) {
  final n = _norm(plan);
  if (n.isEmpty) return false;
  const aliases = {'c', 'cplan', 'planc', 'premium'};
  return aliases.contains(n);
}

bool isCPlanFromData(Map<String, dynamic>? data) {
  final plan = data?['subscription']?['plan'] ?? data?['plan'];
  return _isC(plan);
}

Future<bool> fetchIsCPlan(
  DocumentReference<Map<String, dynamic>> tenantRef,
) async {
  final snap = await tenantRef.get();
  if (!snap.exists) return false;
  return isCPlanFromData(snap.data());
}

Stream<bool> watchIsCPlan(DocumentReference<Map<String, dynamic>> tenantRef) {
  return tenantRef.snapshots().map((snap) => isCPlanFromData(snap.data()));
}

Future<bool> fetchIsCPlanById(String uid, String tenantId) {
  final ref = FirebaseFirestore.instance.collection(uid).doc(tenantId);
  return fetchIsCPlan(ref);
}

/// （既存互換）Bプラン判定
bool _isB(Object? plan) {
  final n = _norm(plan);
  if (n.isEmpty) return false;
  const aliases = {'b', 'bplan', 'planb', 'pro', 'standard'};
  return aliases.contains(n);
}

bool isBPlanFromData(Map<String, dynamic>? data) {
  final plan = data?['subscription']?['plan'] ?? data?['plan'];
  return _isB(plan);
}

Future<bool> fetchIsBPlan(
  DocumentReference<Map<String, dynamic>> tenantRef,
) async {
  final snap = await tenantRef.get();
  if (!snap.exists) return false;
  return isBPlanFromData(snap.data());
}

Stream<bool> watchIsBPlan(DocumentReference<Map<String, dynamic>> tenantRef) {
  return tenantRef.snapshots().map((snap) => isBPlanFromData(snap.data()));
}

Future<bool> fetchIsBPlanById(String uid, String tenantId) {
  final ref = FirebaseFirestore.instance.collection(uid).doc(tenantId);
  return fetchIsBPlan(ref);
}
