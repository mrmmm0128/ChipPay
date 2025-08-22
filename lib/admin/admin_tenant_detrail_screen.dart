import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

class AdminTenantDetailScreen extends StatefulWidget {
  const AdminTenantDetailScreen({super.key});

  @override
  State<AdminTenantDetailScreen> createState() =>
      _AdminTenantDetailScreenState();
}

class _AdminTenantDetailScreenState extends State<AdminTenantDetailScreen> {
  String? tenantId;
  String? tenantName;

  // 売上期間（シンプル版）
  String _range = '30d'; // 'today' | '7d' | '30d' | 'all'

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is Map) {
      tenantId = args['tenantId'] as String?;
      tenantName = args['tenantName'] as String?;
    }
  }

  ({DateTime? start, DateTime? endExclusive}) _bounds() {
    final now = DateTime.now();
    DateTime midnight(DateTime t) => DateTime(t.year, t.month, t.day);
    switch (_range) {
      case 'today':
        final s = midnight(now);
        return (start: s, endExclusive: s.add(const Duration(days: 1)));
      case '7d':
        final e = midnight(now).add(const Duration(days: 1));
        final s = e.subtract(const Duration(days: 7));
        return (start: s, endExclusive: e);
      case '30d':
        final e = midnight(now).add(const Duration(days: 1));
        final s = e.subtract(const Duration(days: 30));
        return (start: s, endExclusive: e);
      default:
        return (start: null, endExclusive: null);
    }
  }

  Future<void> _toggleStatus(String current) async {
    if (tenantId == null) return;
    final to = current == 'suspended' ? 'active' : 'suspended';
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(to == 'suspended' ? '店舗を停止しますか？' : '店舗を再開しますか？'),
        content: Text(
          to == 'suspended' ? '停止中は新規決済・QR発行を不可にします。' : '店舗を通常状態に戻します。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(to == 'suspended' ? '停止する' : '再開する'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await FirebaseFirestore.instance.collection('tenants').doc(tenantId).set({
        'status': to,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('店舗を${to == "suspended" ? "停止" : "再開"}しました')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (tenantId == null) {
      return const Scaffold(body: Center(child: Text('店舗が選択されていません')));
    }

    final tenantRef = FirebaseFirestore.instance
        .collection('tenants')
        .doc(tenantId);

    // 売上クエリ
    final b = _bounds();
    Query tipsQ = tenantRef.collection('tips');
    if (b.start != null) {
      tipsQ = tipsQ.where(
        'createdAt',
        isGreaterThanOrEqualTo: Timestamp.fromDate(b.start!),
      );
    }
    if (b.endExclusive != null) {
      tipsQ = tipsQ.where(
        'createdAt',
        isLessThan: Timestamp.fromDate(b.endExclusive!),
      );
    }
    tipsQ = tipsQ.orderBy('createdAt', descending: true).limit(1000);

    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 0,
        title: Text(
          tenantName ?? '店舗詳細',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      body: StreamBuilder<DocumentSnapshot>(
        stream: tenantRef.snapshots(),
        builder: (context, snap) {
          final data = (snap.data?.data() as Map<String, dynamic>?) ?? {};
          final status = (data['status'] ?? 'unknown').toString();

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // ヘッダ（状態と操作）
              Card(
                elevation: 4,
                shadowColor: Colors.black26,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      _statusChip(status),
                      const SizedBox(width: 12),
                      Text(
                        'ID: ${tenantRef.id}',
                        style: const TextStyle(color: Colors.black54),
                      ),
                      const Spacer(),
                      FilledButton.icon(
                        onPressed: () => _toggleStatus(status),
                        icon: Icon(
                          status == 'suspended'
                              ? Icons.play_arrow
                              : Icons.pause,
                        ),
                        label: Text(status == 'suspended' ? '再開' : '停止'),
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.black,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // 管理者一覧
              Card(
                elevation: 4,
                shadowColor: Colors.black26,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.fromLTRB(4, 6, 4, 10),
                        child: Text(
                          '管理者',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      StreamBuilder<QuerySnapshot>(
                        stream: tenantRef.collection('members').snapshots(),
                        builder: (context, mSnap) {
                          final members = mSnap.data?.docs ?? [];
                          if (members.isEmpty) {
                            final uids =
                                (data['memberUids'] as List?)?.cast<String>() ??
                                const <String>[];
                            if (uids.isEmpty) {
                              return const ListTile(title: Text('管理者がいません'));
                            }
                            return Column(
                              children: uids
                                  .map(
                                    (u) => ListTile(
                                      leading: const CircleAvatar(
                                        backgroundColor: Colors.black,
                                        foregroundColor: Colors.white,
                                        child: Icon(Icons.person),
                                      ),
                                      title: Text(u),
                                      subtitle: const Text('（memberUids）'),
                                    ),
                                  )
                                  .toList(),
                            );
                          }
                          return Column(
                            children: members.map((m) {
                              final md = m.data() as Map<String, dynamic>;
                              return ListTile(
                                leading: const CircleAvatar(
                                  backgroundColor: Colors.black,
                                  foregroundColor: Colors.white,
                                  child: Icon(Icons.person),
                                ),
                                title: Text(md['displayName'] ?? ''),
                                subtitle: Text(md['email'] ?? ''),
                                trailing: Text(md['role'] ?? 'admin'),
                              );
                            }).toList(),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // 売上（件数・金額・内訳）
              Card(
                elevation: 4,
                shadowColor: Colors.black26,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 期間フィルタ
                      Row(
                        children: [
                          _rangePill('今日', 'today'),
                          const SizedBox(width: 8),
                          _rangePill('7日', '7d'),
                          const SizedBox(width: 8),
                          _rangePill('30日', '30d'),
                          const SizedBox(width: 8),
                          _rangePill('全期間', 'all'),
                        ],
                      ),
                      const SizedBox(height: 12),
                      StreamBuilder<QuerySnapshot>(
                        stream: tipsQ.snapshots(),
                        builder: (context, tSnap) {
                          if (tSnap.hasError) {
                            return Text('読み込みエラー: ${tSnap.error}');
                          }
                          if (!tSnap.hasData) {
                            return const Center(
                              child: CircularProgressIndicator(),
                            );
                          }
                          final tips = tSnap.data!.docs;

                          int totalAll = 0, countAll = 0;
                          int totalStore = 0, countStore = 0;
                          int totalStaff = 0, countStaff = 0;

                          for (final doc in tips) {
                            final d = doc.data() as Map<String, dynamic>;
                            final currency =
                                (d['currency'] as String?)?.toUpperCase() ??
                                'JPY';
                            if (currency != 'JPY') continue;
                            final amount = (d['amount'] as num?)?.toInt() ?? 0;

                            countAll++;
                            totalAll += amount;

                            final rec = (d['recipient'] as Map?)
                                ?.cast<String, dynamic>();
                            final employeeId =
                                (d['employeeId'] as String?) ??
                                rec?['employeeId'] as String?;
                            if (employeeId != null && employeeId.isNotEmpty) {
                              countStaff++;
                              totalStaff += amount;
                            } else {
                              countStore++;
                              totalStore += amount;
                            }
                          }

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _metricRow('合計', totalAll, countAll),
                              const SizedBox(height: 8),
                              _metricRow('店舗向け', totalStore, countStore),
                              const SizedBox(height: 8),
                              _metricRow('スタッフ向け', totalStaff, countStaff),
                              const SizedBox(height: 16),
                              const Divider(),
                              const SizedBox(height: 8),
                              const Text(
                                '最近の決済',
                                style: TextStyle(fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 8),
                              ...tips.take(20).map((e) {
                                final d = e.data() as Map<String, dynamic>;
                                final amount =
                                    (d['amount'] as num?)?.toInt() ?? 0;
                                final ts = d['createdAt'];
                                String when = '';
                                if (ts is Timestamp) {
                                  final dt = ts.toDate().toLocal();
                                  when =
                                      '${dt.year}/${dt.month.toString().padLeft(2, "0")}/${dt.day.toString().padLeft(2, "0")} '
                                      '${dt.hour.toString().padLeft(2, "0")}:${dt.minute.toString().padLeft(2, "0")}';
                                }
                                final rec = (d['recipient'] as Map?)
                                    ?.cast<String, dynamic>();
                                final isEmp =
                                    (rec?['type'] == 'employee') ||
                                    (d['employeeId'] != null);
                                final who = isEmp
                                    ? 'スタッフ: ${rec?['employeeName'] ?? d['employeeName'] ?? 'スタッフ'}'
                                    : '店舗: ${rec?['storeName'] ?? d['storeName'] ?? '店舗'}';
                                return ListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  leading: const Icon(Icons.receipt_long),
                                  title: Text(
                                    who,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(when),
                                  trailing: Text(
                                    '¥$amount',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                );
                              }),
                            ],
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  // ---- UI helpers ----
  Widget _statusChip(String status) {
    final dark = status == 'suspended';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: dark ? Colors.black : Colors.white,
        border: Border.all(color: Colors.black54),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        status == 'suspended' ? '停止中' : '稼働中',
        style: TextStyle(
          color: dark ? Colors.white : Colors.black,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _rangePill(String label, String key) {
    final active = _range == key;
    return InkWell(
      onTap: () => setState(() => _range = key),
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: active ? Colors.black : Colors.white,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.black12),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? Colors.white : Colors.black87,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _metricRow(String title, int yen, int count) {
    return Row(
      children: [
        SizedBox(
          width: 90,
          child: Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '¥$yen  /  $count件',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}
