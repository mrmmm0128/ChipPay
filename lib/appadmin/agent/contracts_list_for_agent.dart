import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:yourpay/appadmin/admin_dashboard_screen.dart';
import 'package:yourpay/appadmin/tenant/tenant_detail.dart';

enum _ChipKind { good, warn, bad }

class ContractsListForAgent extends StatelessWidget {
  final String agentId;
  const ContractsListForAgent({required this.agentId});

  String _ymdhm(DateTime d) =>
      '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  String _ymd(DateTime d) =>
      '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('agencies')
          .doc(agentId)
          .collection('contracts')
          .orderBy('contractedAt', descending: true)
          .limit(200)
          .snapshots(),
      builder: (context, snap) {
        if (snap.hasError) {
          return ListTile(title: Text('読込エラー: ${snap.error}'));
        }
        if (!snap.hasData) {
          return const Padding(
            padding: EdgeInsets.all(12),
            child: SizedBox(
              height: 20,
              width: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        final docs = snap.data!.docs;
        if (docs.isEmpty) {
          return const ListTile(title: Text('登録店舗はまだありません'));
        }

        return Column(
          children: docs.map((d) {
            final m = d.data();
            final tenantId = (m['tenantId'] ?? '').toString();
            final tenantName = (m['tenantName'] ?? '(no name)').toString();
            final whenTs = m['contractedAt'];
            final when = (whenTs is Timestamp) ? whenTs.toDate() : null;
            final ownerUidFromContract = (m['ownerUid'] ?? '').toString();

            return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
              stream: FirebaseFirestore.instance
                  .collection('tenantIndex')
                  .doc(tenantId)
                  .snapshots(),
              builder: (context, st) {
                final tm = st.data?.data() ?? {};
                final init = (tm['billing']?['initialFee']?['status'] ?? 'none')
                    .toString();
                final subSt = (tm['subscription']?['status'] ?? '').toString();
                final subPl = (tm['subscription']?['plan'] ?? '選択なし')
                    .toString();
                final chg = tm['connect']?['charges_enabled'] == true;

                // 次回日（nextPaymentAt or currentPeriodEnd）
                final _nextRaw =
                    tm['subscription']?['nextPaymentAt'] ??
                    tm['subscription']?['currentPeriodEnd'];
                final nextAt = (_nextRaw is Timestamp)
                    ? _nextRaw.toDate()
                    : null;

                // 未払いフラグ
                final overdue =
                    tm['subscription']?['overdue'] == true ||
                    subSt == 'past_due' ||
                    subSt == 'unpaid';

                // ownerUid は contracts に無ければ index の uid をフォールバック
                final ownerUid = ownerUidFromContract.isNotEmpty
                    ? ownerUidFromContract
                    : (tm['uid'] ?? '').toString();

                return ListTile(
                  dense: true,
                  leading: const Icon(Icons.store),
                  title: Text(tenantName),
                  subtitle: Text(
                    [
                      'tenantId: $tenantId',
                      if (ownerUid.isNotEmpty) 'ownerUid: $ownerUid',
                      if (when != null) '契約: ${_ymdhm(when)}',
                    ].join('  •  '),
                  ),
                  trailing: Wrap(
                    spacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _mini(
                        init == 'paid'
                            ? '初期費用済'
                            : init == 'checkout_open'
                            ? '初期費用:決済中'
                            : '初期費用:未払い',
                        init == 'paid'
                            ? _ChipKind.good
                            : (init == 'checkout_open'
                                  ? _ChipKind.warn
                                  : _ChipKind.bad),
                      ),
                      _mini(
                        'サブスク:$subPl ${subSt.toUpperCase()}'
                        '${nextAt != null ? '・次回:${_ymd(nextAt)}' : ''}'
                        '${overdue ? '・未払い' : ''}',
                        overdue
                            ? _ChipKind.bad
                            : (subSt == 'active' || subSt == 'trialing')
                            ? _ChipKind.good
                            : _ChipKind.bad,
                      ),
                      _mini(
                        chg ? 'コネクトアカウント登録済' : 'コネクトアカウント未登録',
                        chg ? _ChipKind.good : _ChipKind.bad,
                      ),
                      const Icon(Icons.chevron_right),
                    ],
                  ),
                  onTap: () {
                    if (tenantId.isEmpty) return;
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => AdminTenantDetailPage(
                          ownerUid: ownerUid,
                          tenantId: tenantId,
                          tenantName: tenantName,
                        ),
                      ),
                    );
                  },
                );
              },
            );
          }).toList(),
        );
      },
    );
  }

  Widget _mini(String label, _ChipKind kind) {
    final color = switch (kind) {
      _ChipKind.good => const Color(0xFF1B5E20),
      _ChipKind.warn => const Color(0xFFB26A00),
      _ChipKind.bad => const Color(0xFFB00020),
    };
    final bg = color.withOpacity(0.08);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w600,
          fontSize: 11,
        ),
      ),
    );
  }
}
