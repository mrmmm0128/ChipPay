import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:yourpay/tenant/store_detail/card_shell.dart';

class PeriodPaymentsPage extends StatefulWidget {
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

  @override
  State<PeriodPaymentsPage> createState() => _PeriodPaymentsPageState();
}

class _PeriodPaymentsPageState extends State<PeriodPaymentsPage> {
  final _searchCtrl = TextEditingController();
  String _search = '';
  Timer? _debounce;
  final uid = FirebaseAuth.instance.currentUser?.uid;

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() {
      // 入力のデバウンス（タイプ中の過剰rebuild防止）
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 180), () {
        setState(() => _search = _searchCtrl.text.trim().toLowerCase());
      });
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

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
    if (widget.start == null && widget.endExclusive == null) return '全期間';
    String f(DateTime d) =>
        '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';
    final s = widget.start != null ? f(widget.start!) : '…';
    final e = (widget.endExclusive != null)
        ? f(widget.endExclusive!.subtract(const Duration(days: 1)))
        : '…';
    return '$s 〜 $e';
  }

  Query _buildQuery() {
    Query q = FirebaseFirestore.instance
        .collection(uid!)
        .doc(widget.tenantId)
        .collection('tips')
        .where('status', isEqualTo: 'succeeded');

    if (widget.start != null) {
      q = q.where(
        'createdAt',
        isGreaterThanOrEqualTo: Timestamp.fromDate(widget.start!),
      );
    }
    if (widget.endExclusive != null) {
      q = q.where(
        'createdAt',
        isLessThan: Timestamp.fromDate(widget.endExclusive!),
      );
    }

    // createdAt 降順・最大500件
    return q.orderBy('createdAt', descending: true).limit(500);
  }

  String _nameFrom(Map<String, dynamic> d) {
    final rec = (d['recipient'] as Map?)?.cast<String, dynamic>();
    final isEmp = (rec?['type'] == 'employee') || (d['employeeId'] != null);
    if (isEmp) {
      return (rec?['employeeName'] ?? d['employeeName'] ?? 'スタッフ').toString();
    } else {
      return (rec?['storeName'] ?? d['storeName'] ?? '店舗').toString();
    }
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
          widget.tenantName == null ? '決済履歴' : '${widget.tenantName!} の決済履歴',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(84),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _rangeLabel(),
                  style: const TextStyle(color: Colors.black54),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _searchCtrl,
                  decoration: InputDecoration(
                    hintText: '名前で検索（スタッフ名 / 店舗名）',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _search.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () => _searchCtrl.clear(),
                          ),
                    isDense: true,
                    filled: true,
                    fillColor: const Color(0xFFF0F0F0),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ],
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

          // ★ クライアント側フィルタ（部分一致・大文字小文字無視）
          final filtered = (() {
            if (_search.isEmpty) return docs;
            return docs.where((doc) {
              final d = doc.data() as Map<String, dynamic>;
              final name = _nameFrom(d).toLowerCase();
              return name.contains(_search);
            }).toList();
          })();

          if (filtered.isEmpty) {
            return const Center(child: Text('該当するデータはありません'));
          }

          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: filtered.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (_, i) {
              final d = filtered[i].data() as Map<String, dynamic>;
              final rec = (d['recipient'] as Map?)?.cast<String, dynamic>();
              final isEmp =
                  (rec?['type'] == 'employee') || (d['employeeId'] != null);

              final who = isEmp
                  ? 'スタッフ: ${rec?['employeeName'] ?? d['employeeName'] ?? 'スタッフ'}'
                  : '店舗: ${rec?['storeName'] ?? d['storeName'] ?? '店舗'}';

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
