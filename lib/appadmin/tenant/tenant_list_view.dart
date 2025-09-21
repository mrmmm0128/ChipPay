import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:yourpay/appadmin/tenant/tenant_detail.dart';
import 'package:yourpay/appadmin/tenant/tenant_tile.dart';
import 'package:yourpay/appadmin/util.dart';

class TenantsListView extends StatelessWidget {
  final String query;
  final bool filterActiveOnly;
  final bool filterChargesEnabledOnly;
  final SortBy sortBy;
  final DateTime? rangeStart;
  final DateTime? rangeEndEx;
  final Future<Revenue> Function({
    required String tenantId,
    required String ownerUid,
  })
  loadRevenueForTenant;
  final String Function(int) yen;
  final String Function(DateTime) ymd;

  const TenantsListView({
    super.key,
    required this.query,
    required this.filterActiveOnly,
    required this.filterChargesEnabledOnly,
    required this.sortBy,
    required this.rangeStart,
    required this.rangeEndEx,
    required this.loadRevenueForTenant,
    required this.yen,
    required this.ymd,
  });

  @override
  Widget build(BuildContext context) {
    // 1) まず tenantIndex を購読して ownerUid/tenantId のペアだけ取得
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection('tenantIndex').snapshots(),
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(child: Text('読込エラー: ${snap.error}'));
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final pairs = <({String ownerUid, String tenantId})>[];
        for (final d in snap.data!.docs) {
          final uid = d.data()['uid'];
          if (uid is String && uid.isNotEmpty) {
            pairs.add((ownerUid: uid, tenantId: d.id));
          }
        }
        if (pairs.isEmpty) {
          return const Center(child: Text('店舗がありません'));
        }

        // 2) 本体ドキュメントを一括 get（重いが確実）
        return FutureBuilder<List<DocumentSnapshot<Map<String, dynamic>>>>(
          future: Future.wait(
            pairs.map(
              (p) => FirebaseFirestore.instance
                  .collection(p.ownerUid)
                  .doc(p.tenantId)
                  .get(),
            ),
          ),
          builder: (context, f) {
            if (f.hasError) {
              return Center(child: Text('読込エラー: ${f.error}'));
            }
            if (f.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }

            final rows = <_Row>[];
            for (var i = 0; i < pairs.length; i++) {
              final snap = f.data![i];
              if (!snap.exists) continue;
              final p = pairs[i];
              rows.add(
                _Row(
                  ownerUid: p.ownerUid,
                  tenantId: p.tenantId,
                  data: snap.data() ?? {},
                ),
              );
            }

            // ===== ヘルパ =====
            String _s(dynamic v) => v == null ? '' : v.toString();
            String _nonEmptyOr(dynamic v, String fallback) {
              final s = _s(v).trim();
              return s.isEmpty ? fallback : s;
            }

            Timestamp? _ts(dynamic v) => v is Timestamp ? v : null;
            bool _chargesEnabledOf(Map<String, dynamic> m) =>
                (m['connect'] is Map) &&
                (((m['connect'] as Map)['charges_enabled']) == true);

            // 3) クライアント側で検索・フィルタ・ソート（すべて owner 本体基準）
            var filtered = rows.where((r) {
              if (query.trim().isEmpty) return true;
              final q = query.trim().toLowerCase();
              final name = _s(r.data['name']).toLowerCase();
              final id = r.tenantId.toLowerCase();
              final owner = r.ownerUid.toLowerCase();
              return name.contains(q) || id.contains(q) || owner.contains(q);
            }).toList();

            if (filterActiveOnly) {
              filtered = filtered
                  .where((r) => _s(r.data['status']) == 'active')
                  .toList();
            }
            if (filterChargesEnabledOnly) {
              filtered = filtered
                  .where((r) => _chargesEnabledOf(r.data))
                  .toList();
            }

            if (sortBy == SortBy.nameAsc) {
              filtered.sort(
                (a, b) => _s(a.data['name']).compareTo(_s(b.data['name'])),
              );
            } else if (sortBy == SortBy.createdDesc) {
              filtered.sort((a, b) {
                final da =
                    _ts(a.data['createdAt'])?.toDate() ??
                    DateTime.fromMillisecondsSinceEpoch(0);
                final db =
                    _ts(b.data['createdAt'])?.toDate() ??
                    DateTime.fromMillisecondsSinceEpoch(0);
                return db.compareTo(da);
              });
            } else if (sortBy == SortBy.revenueDesc) {
              // 表示時ロードのためここでは未ソート（必要なら集計後に再整列）
            }

            if (filtered.isEmpty) {
              return const Center(child: Text('条件に一致する店舗がありません'));
            }

            return ListView.separated(
              itemCount: filtered.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final r = filtered[i];
                final m = r.data;

                // フィールドが全部 null / 空でも安全に表示
                final name = _nonEmptyOr(m['name'], '設定なし');
                final status = _nonEmptyOr(m['status'], '設定なし');
                final createdAt = _ts(m['createdAt'])?.toDate(); // null 可
                final chargesEnabled = _chargesEnabledOf(m); // missing → false

                // サブスク
                final sub = (m['subscription'] is Map)
                    ? (m['subscription'] as Map)
                    : const <String, dynamic>{};
                final subStatus = _nonEmptyOr(sub['status'], '設定なし');
                final subPlan = _nonEmptyOr(sub['plan'], '設定なし');
                final nextRaw = sub['nextPaymentAt'] ?? sub['currentPeriodEnd'];
                final nextAt = _ts(nextRaw)?.toDate(); // null 可
                final overdue =
                    (sub['overdue'] == true) ||
                    subStatus == 'past_due' ||
                    subStatus == 'unpaid';

                return TenantTile(
                  tenantId: r.tenantId,
                  ownerUid: r.ownerUid,
                  name: name,
                  status: status,
                  plan: subPlan,
                  chargesEnabled: chargesEnabled,
                  createdAt: createdAt,
                  download: m['download'],
                  rangeLabel: (rangeStart != null && rangeEndEx != null)
                      ? '${ymd(rangeStart!)} 〜 ${ymd(rangeEndEx!.subtract(const Duration(days: 1)))}'
                      : '期間未設定',
                  loadRevenue: () => loadRevenueForTenant(
                    tenantId: r.tenantId,
                    ownerUid: r.ownerUid,
                  ),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => AdminTenantDetailPage(
                          ownerUid: r.ownerUid,
                          tenantId: r.tenantId,
                          tenantName: name,
                        ),
                      ),
                    );
                  },
                  yen: yen,
                  subPlan: subPlan, // 「設定なし」になる
                  subStatus: subStatus, // 「設定なし」になる
                  subOverdue: overdue,
                  subNextPaymentAt: nextAt, // null のまま可
                );
              },
            );
          },
        );
      },
    );
  }
}

class _Row {
  final String ownerUid;
  final String tenantId;
  final Map<String, dynamic> data;
  _Row({required this.ownerUid, required this.tenantId, required this.data});
}
