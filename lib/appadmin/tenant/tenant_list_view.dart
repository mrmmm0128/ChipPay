import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:yourpay/appadmin/admin_dashboard_screen.dart';
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
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection('tenantIndex').snapshots(),
      builder: (context, snap) {
        if (snap.hasError) return Center(child: Text('読込エラー: ${snap.error}'));
        if (!snap.hasData)
          return const Center(child: CircularProgressIndicator());

        var docs = snap.data!.docs;

        // 検索
        if (query.isNotEmpty) {
          final q = query.toLowerCase();
          docs = docs.where((d) {
            final name = (d.data()['name'] ?? '').toString().toLowerCase();
            final id = d.id.toLowerCase();
            return name.contains(q) || id.contains(q);
          }).toList();
        }
        // フィルタ
        if (filterActiveOnly) {
          docs = docs.where((d) => d.data()['status'] == 'active').toList();
        }
        if (filterChargesEnabledOnly) {
          docs = docs
              .where((d) => (d.data()['connect']?['charges_enabled'] == true))
              .toList();
        }
        // ソート
        if (sortBy == SortBy.nameAsc) {
          docs.sort(
            (a, b) => (a.data()['name'] ?? '').toString().compareTo(
              (b.data()['name'] ?? '').toString(),
            ),
          );
        } else if (sortBy == SortBy.createdDesc) {
          docs.sort((a, b) {
            final ta = (a.data()['createdAt'] as Timestamp?);
            final tb = (b.data()['createdAt'] as Timestamp?);
            final da = ta?.toDate() ?? DateTime.fromMillisecondsSinceEpoch(0);
            final db = tb?.toDate() ?? DateTime.fromMillisecondsSinceEpoch(0);
            return db.compareTo(da);
          });
        }

        if (docs.isEmpty) return const Center(child: Text('店舗がありません'));

        return ListView.separated(
          itemCount: docs.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, i) {
            final d = docs[i];
            final m = d.data();

            final tenantId = d.id;
            final ownerUid = (m['uid'] ?? '').toString();
            final name = (m['name'] ?? '(no name)').toString();
            final status = (m['status'] ?? '').toString();
            final plan = (m['subscription']?['plan'] ?? '').toString();
            final chargesEnabled = m['connect']?['charges_enabled'] == true;
            final createdAt = (m['createdAt'] as Timestamp?)?.toDate();

            // ▼ 追加：サブスクの次回日・未払い
            final subStatus = (m['subscription']?['status'] ?? 'none')
                .toString();
            final subPlan = (m['subscription']?['plan'] ?? '-').toString();
            final nextRaw =
                m['subscription']?['nextPaymentAt'] ??
                m['subscription']?['currentPeriodEnd'];
            final nextAt = (nextRaw is Timestamp) ? nextRaw.toDate() : null;
            final overdue =
                m['subscription']?['overdue'] == true ||
                subStatus == 'past_due' ||
                subStatus == 'unpaid';

            return TenantTile(
              tenantId: tenantId,
              ownerUid: ownerUid,
              name: name,
              status: status,
              plan: plan,
              chargesEnabled: chargesEnabled,
              createdAt: createdAt,
              rangeLabel: (rangeStart != null && rangeEndEx != null)
                  ? '${ymd(rangeStart!)} 〜 ${ymd(rangeEndEx!.subtract(const Duration(days: 1)))}'
                  : '期間未設定',
              loadRevenue: () =>
                  loadRevenueForTenant(tenantId: tenantId, ownerUid: ownerUid),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => AdminTenantDetailPage(
                      ownerUid: ownerUid,
                      tenantId: tenantId,
                      tenantName: name,
                    ),
                  ),
                );
              },
              yen: yen,
              // 追加分
              subPlan: subPlan,
              subStatus: subStatus,
              subOverdue: overdue,
              subNextPaymentAt: nextAt,
            );
          },
        );
      },
    );
  }
}
