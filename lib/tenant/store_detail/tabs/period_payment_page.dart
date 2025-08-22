import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:yourpay/tenant/store_detail/card_shell.dart';

class PeriodPaymentsPage extends StatelessWidget {
  final String tenantId;
  final String? tenantName;
  final DateTime? start;
  final DateTime? endExclusive;

  const PeriodPaymentsPage({
    super.key,
    required this.tenantId,
    this.tenantName,
    this.start,
    this.endExclusive,
  });

  String _symbol(String code) {
    switch (code.toUpperCase()) {
      case 'JPY':
        return '¥';
      case 'USD':
        return '\$';
      case 'EUR':
        return '€';
      default:
        return '';
    }
  }

  String _rangeLabel() {
    if (start == null && endExclusive == null) return '全期間';
    String f(DateTime d) =>
        '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';
    final s = start != null ? f(start!) : '…';
    final e = (endExclusive != null)
        ? f(endExclusive!.subtract(const Duration(days: 1)))
        : '…';
    return '$s 〜 $e';
    // endExclusive は日付の翌日なので -1day で表示
  }

  Query _buildQuery() {
    Query q = FirebaseFirestore.instance
        .collection('tenants')
        .doc(tenantId)
        .collection('tips')
        .where('status', isEqualTo: 'succeeded'); // 成功のみ

    if (start != null) {
      q = q.where(
        'createdAt',
        isGreaterThanOrEqualTo: Timestamp.fromDate(start!),
      );
    }
    if (endExclusive != null) {
      q = q.where('createdAt', isLessThan: Timestamp.fromDate(endExclusive!));
    }

    // createdAt 降順で最新から
    q = q.orderBy('createdAt', descending: true).limit(500);

    // ⚠ 初回は「index が必要」リンクが出る場合があります。リンクを押して
    //   (status Asc/Desc, createdAt Desc) の複合インデックスを作成してください。
    return q;
  }

  @override
  Widget build(BuildContext context) {
    final q = _buildQuery();

    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 0,
        title: Text(
          tenantName == null ? '決済履歴' : '${tenantName!} の決済履歴',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(34),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _rangeLabel(),
                style: const TextStyle(color: Colors.black54),
              ),
            ),
          ),
        ),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: q.snapshots(),
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: Text('読み込みエラー: ${snap.error}'));
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final docs = snap.data!.docs;
          if (docs.isEmpty) {
            return const Center(child: Text('この期間のデータはありません'));
          }

          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: docs.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (_, i) {
              final d = docs[i].data() as Map<String, dynamic>;
              final recipient = (d['recipient'] as Map?)
                  ?.cast<String, dynamic>();
              final isEmp =
                  (recipient?['type'] == 'employee') ||
                  (d['employeeId'] != null);

              final who = isEmp
                  ? 'スタッフ: ${recipient?['employeeName'] ?? d['employeeName'] ?? 'スタッフ'}'
                  : '店舗: ${recipient?['storeName'] ?? d['storeName'] ?? '店舗'}';

              final amountNum = (d['amount'] as num?) ?? 0;
              final currency =
                  (d['currency'] as String?)?.toUpperCase() ?? 'JPY';
              final sym = _symbol(currency);
              final amountText = sym.isNotEmpty
                  ? '$sym${amountNum.toInt()}'
                  : '${amountNum.toInt()} $currency';

              String when = '';
              final ts = d['createdAt'];
              if (ts is Timestamp) {
                final dt = ts.toDate().toLocal();
                when =
                    '${dt.year}/${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')} '
                    '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
              }

              return CardShell(
                child: ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Colors.black,
                    foregroundColor: Colors.white,
                    child: Icon(Icons.receipt_long),
                  ),
                  title: Text(
                    who,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      color: Colors.black87,
                    ),
                  ),
                  subtitle: Text(
                    when,
                    style: const TextStyle(color: Colors.black87),
                  ),
                  trailing: Text(
                    amountText,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: Colors.black87,
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
