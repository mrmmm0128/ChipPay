// tabs/payments_tab.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:yourpay/tenant/store_detail/card_shell.dart';
import 'package:yourpay/tenant/store_detail/range_pill.dart';

class StorePaymentsTab extends StatefulWidget {
  final String tenantId;
  const StorePaymentsTab({super.key, required this.tenantId});

  @override
  State<StorePaymentsTab> createState() => _StorePaymentsTabState();
}

enum _RangeFilter { today, last7, last30, all, custom }

class _StorePaymentsTabState extends State<StorePaymentsTab> {
  // 名前検索
  final _searchCtrl = TextEditingController();
  String _query = '';

  // 期間
  _RangeFilter _range = _RangeFilter.last30;
  DateTimeRange? _customRange;

  // ★ 追加：成功のみ表示トグル
  bool _onlySucceeded = false;

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(
      () => setState(() => _query = _searchCtrl.text.trim().toLowerCase()),
    );
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  String _rangeLabel() {
    switch (_range) {
      case _RangeFilter.today:
        return '今日';
      case _RangeFilter.last7:
        return '直近7日';
      case _RangeFilter.last30:
        return '直近30日';
      case _RangeFilter.all:
        return '全期間';
      case _RangeFilter.custom:
        if (_customRange == null) return '期間指定';
        String f(DateTime d) =>
            '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';
        return '${f(_customRange!.start)}〜${f(_customRange!.end)}';
    }
  }

  ({DateTime? start, DateTime? endExclusive}) _rangeBounds() {
    final now = DateTime.now();
    DateTime midnight(DateTime t) => DateTime(t.year, t.month, t.day);
    switch (_range) {
      case _RangeFilter.today:
        final s = midnight(now);
        return (start: s, endExclusive: s.add(const Duration(days: 1)));
      case _RangeFilter.last7:
        final e = midnight(now).add(const Duration(days: 1));
        final s = e.subtract(const Duration(days: 7));
        return (start: s, endExclusive: e);
      case _RangeFilter.last30:
        final e = midnight(now).add(const Duration(days: 1));
        final s = e.subtract(const Duration(days: 30));
        return (start: s, endExclusive: e);
      case _RangeFilter.all:
        return (start: null, endExclusive: null);
      case _RangeFilter.custom:
        if (_customRange == null) return (start: null, endExclusive: null);
        final s = DateTime(
          _customRange!.start.year,
          _customRange!.start.month,
          _customRange!.start.day,
        );
        final e = DateTime(
          _customRange!.end.year,
          _customRange!.end.month,
          _customRange!.end.day,
        ).add(const Duration(days: 1));
        return (start: s, endExclusive: e);
    }
  }

  Future<void> _pickCustomRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 1),
      initialDateRange:
          _customRange ??
          DateTimeRange(start: now.subtract(const Duration(days: 6)), end: now),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: Theme.of(context).colorScheme.copyWith(
            primary: Colors.black,
            onPrimary: Colors.white,
          ),
        ),
        child: child!,
      ),
    );
    if (picked != null) {
      setState(() {
        _range = _RangeFilter.custom;
        _customRange = picked;
      });
    }
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

  @override
  Widget build(BuildContext context) {
    // 期間に応じてクエリ（createdAtのみで絞る）
    final b = _rangeBounds();
    Query tipsQ = FirebaseFirestore.instance
        .collection('tenants')
        .doc(widget.tenantId)
        .collection('tips');
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
    tipsQ = tipsQ.orderBy('createdAt', descending: true).limit(200);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // --- 名前検索 ---
          TextField(
            controller: _searchCtrl,
            decoration: InputDecoration(
              hintText: '名前で検索（スタッフ/店舗）',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () => _searchCtrl.clear(),
                    ),
              filled: true,
              fillColor: Colors.white,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 12,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Colors.black12),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Colors.black12),
              ),
            ),
          ),
          const SizedBox(height: 10),

          // --- 期間ピル + 成功のみチップ ---
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                RangePill(
                  label: '今日',
                  active: _range == _RangeFilter.today,
                  onTap: () => setState(() => _range = _RangeFilter.today),
                ),
                const SizedBox(width: 8),
                RangePill(
                  label: '7日',
                  active: _range == _RangeFilter.last7,
                  onTap: () => setState(() => _range = _RangeFilter.last7),
                ),
                const SizedBox(width: 8),
                RangePill(
                  label: '30日',
                  active: _range == _RangeFilter.last30,
                  onTap: () => setState(() => _range = _RangeFilter.last30),
                ),
                const SizedBox(width: 8),
                RangePill(
                  label: '全期間',
                  active: _range == _RangeFilter.all,
                  onTap: () => setState(() => _range = _RangeFilter.all),
                ),
                const SizedBox(width: 8),
                RangePill(
                  label: _rangeLabel(),
                  active: _range == _RangeFilter.custom,
                  icon: Icons.date_range,
                  onTap: _pickCustomRange,
                ),
                const SizedBox(width: 12),
                // ★ 成功のみ
                FilterChip(
                  selected: _onlySucceeded,
                  onSelected: (v) => setState(() => _onlySucceeded = v),
                  label: Text(
                    '成功のみ',
                    style: TextStyle(
                      color: _onlySucceeded ? Colors.white : Colors.black87,
                    ),
                  ),
                  avatar: Icon(
                    Icons.check_circle_outline,
                    size: 18,
                    color: _onlySucceeded ? Colors.white : Colors.black54,
                  ),
                  selectedColor: Colors.black,
                  checkmarkColor: Colors.white,
                  backgroundColor: Colors.white,
                  shape: StadiumBorder(side: BorderSide(color: Colors.black12)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          const Text(
            '直近セッション',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: Colors.black87,
            ),
          ),
          const SizedBox(height: 8),

          // --- リスト ---
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: tipsQ.snapshots(),
              builder: (context, snap) {
                if (snap.hasError) {
                  return Center(
                    child: CardShell(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text('読み込みエラー: ${snap.error}'),
                      ),
                    ),
                  );
                }
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }

                // 名前 & 成功のみ をクライアント側でフィルタ
                final all = snap.data?.docs ?? [];
                final docs = all.where((doc) {
                  final d = doc.data() as Map<String, dynamic>;
                  // success フィルタ
                  if (_onlySucceeded) {
                    final st = (d['status'] ?? '').toString().toLowerCase();
                    if (st != 'succeeded') return false;
                  }
                  // 名前フィルタ
                  if (_query.isEmpty) return true;
                  final recipient = (d['recipient'] as Map?)
                      ?.cast<String, dynamic>();
                  final isEmp =
                      (recipient?['type'] == 'employee') ||
                      (d['employeeId'] != null);
                  final empName =
                      (d['employeeName'] ?? recipient?['employeeName'] ?? '')
                          .toString()
                          .toLowerCase();
                  final storeName =
                      (d['storeName'] ?? recipient?['storeName'] ?? '')
                          .toString()
                          .toLowerCase();
                  final target = isEmp ? empName : storeName;
                  return target.contains(_query);
                }).toList();

                if (docs.isEmpty) {
                  return const Center(child: Text('該当する履歴がありません'));
                }

                return ListView.separated(
                  itemCount: docs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (_, i) {
                    final d = docs[i].data() as Map<String, dynamic>;
                    final recipient = (d['recipient'] as Map?)
                        ?.cast<String, dynamic>();
                    final isEmployee =
                        (recipient?['type'] == 'employee') ||
                        (d['employeeId'] != null);
                    final employeeName =
                        recipient?['employeeName'] ??
                        d['employeeName'] ??
                        'スタッフ';
                    final storeName =
                        recipient?['storeName'] ?? d['storeName'] ?? '店舗';
                    final targetLabel = isEmployee
                        ? 'スタッフ: $employeeName'
                        : '店舗: $storeName';

                    final amountNum = (d['amount'] as num?) ?? 0;
                    final currency =
                        (d['currency'] as String?)?.toUpperCase() ?? 'JPY';
                    final amountText = (_symbol(currency).isNotEmpty)
                        ? '${_symbol(currency)}${amountNum.toInt()}'
                        : '${amountNum.toInt()} $currency';

                    final status = (d['status'] as String?) ?? 'unknown';
                    final ts = d['createdAt'];
                    String when = '';
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
                          targetLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            color: Colors.black87,
                          ),
                        ),
                        subtitle: Text(
                          [
                            'ステータス: $status',
                            if (when.isNotEmpty) when,
                          ].join('  •  '),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
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
          ),
        ],
      ),
    );
  }
}
