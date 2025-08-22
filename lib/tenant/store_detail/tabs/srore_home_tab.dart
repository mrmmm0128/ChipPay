// tabs/home_tab.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher_string.dart';

import 'package:yourpay/tenant/store_detail/card_shell.dart';
import 'package:yourpay/tenant/store_detail/home_metrics.dart';
import 'package:yourpay/tenant/store_detail/range_pill.dart';
import 'package:yourpay/tenant/store_detail/rank_entry.dart';
import 'package:yourpay/tenant/store_detail/tabs/period_payment_page.dart'; // RankEntry

class StoreHomeTab extends StatefulWidget {
  final String tenantId;
  final String? tenantName;
  const StoreHomeTab({super.key, required this.tenantId, this.tenantName});

  @override
  State<StoreHomeTab> createState() => _StoreHomeTabState();
}

// ==== 期間フィルタ ====
enum _RangeFilter { today, last7, last30, all, custom }

class _StoreHomeTabState extends State<StoreHomeTab> {
  final _functions = FirebaseFunctions.instanceFor(region: 'us-central1');

  bool loading = false;
  String? publicStoreUrl;

  _RangeFilter _range = _RangeFilter.last30;
  DateTimeRange? _customRange;

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

  // 追加: 期間付きの履歴ページへ遷移
  void _openPeriodPayments() {
    final b = _rangeBounds(); // 現在の期間
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PeriodPaymentsPage(
          tenantId: widget.tenantId,
          tenantName: widget.tenantName,
          start: b.start,
          endExclusive: b.endExclusive,
        ),
      ),
    );
  }

  Future<void> _openOnboarding() async {
    final res = await _functions
        .httpsCallable('createAccountOnboardingLink')
        .call({'tenantId': widget.tenantId});
    final url = (res.data as Map)['url'] as String;
    await launchUrlString(url, mode: LaunchMode.externalApplication);
  }

  void _makeStoreQr() {
    final origin = Uri.base.origin;
    setState(() => publicStoreUrl = '$origin/#/p?t=${widget.tenantId}');
  }

  @override
  Widget build(BuildContext context) {
    final primaryBtnStyle = FilledButton.styleFrom(
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      padding: const EdgeInsets.symmetric(vertical: 14),
    );
    final outlinedBtnStyle = OutlinedButton.styleFrom(
      foregroundColor: Colors.black87,
      side: const BorderSide(color: Colors.black87),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    );

    // フィルタ UI
    final filterBar = Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SingleChildScrollView(
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
          ],
        ),
      ),
    );

    // 期間境界で tips クエリ
    final bounds = _rangeBounds();
    Query tipsQ = FirebaseFirestore.instance
        .collection('tenants')
        .doc(widget.tenantId)
        .collection('tips')
        .where('status', isEqualTo: 'succeeded'); // ← 追加

    if (bounds.start != null) {
      tipsQ = tipsQ.where(
        'createdAt',
        isGreaterThanOrEqualTo: Timestamp.fromDate(bounds.start!),
      );
    }
    if (bounds.endExclusive != null) {
      tipsQ = tipsQ.where(
        'createdAt',
        isLessThan: Timestamp.fromDate(bounds.endExclusive!),
      );
    }
    tipsQ = tipsQ.orderBy('createdAt', descending: true).limit(1000);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // フィルタ（既存）
          // Stripe接続状況 + QR発行（既存をそのまま）
          StreamBuilder<DocumentSnapshot>(
            stream: FirebaseFirestore.instance
                .collection('tenants')
                .doc(widget.tenantId)
                .snapshots(),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: LinearProgressIndicator(minHeight: 2),
                );
              }
              final data = snap.data?.data() as Map<String, dynamic>?;
              final hasAccount =
                  ((data?['stripeAccountId'] as String?)?.isNotEmpty ?? false);
              final connected =
                  (data?['connect']?['charges_enabled'] as bool?) ?? false;

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!connected)
                    CardShell(
                      child: ListTile(
                        leading: const CircleAvatar(
                          backgroundColor: Colors.amber,
                          foregroundColor: Colors.black,
                          child: Icon(Icons.info_outline),
                        ),
                        title: Text(
                          hasAccount
                              ? 'Stripeオンボーディング未完了のため、QR発行はできません。'
                              : 'Stripe未接続のため、QR発行はできません。',
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            color: Colors.black87,
                          ),
                        ),
                        subtitle: const Text(
                          '決済を受け付けるにはStripeに接続し、オンボーディングを完了してください。',
                          style: TextStyle(color: Colors.black87),
                        ),
                        trailing: Padding(
                          padding: const EdgeInsets.only(
                            left: 8,
                            right: 4,
                          ), // ← 外側の余白
                          child: FilledButton(
                            style: primaryBtnStyle.copyWith(
                              padding: MaterialStateProperty.all(
                                const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 12,
                                ), // ← 内側余白
                              ),
                              minimumSize: MaterialStateProperty.all(
                                const Size(0, 44),
                              ), // ← タッチサイズ
                              tapTargetSize: MaterialTapTargetSize
                                  .shrinkWrap, // ← ListTileの高さを過度に広げない
                              shape: MaterialStateProperty.all(
                                RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ),
                            onPressed: _openOnboarding,
                            child: Text(
                              hasAccount ? '続きから再開' : 'Stripeに接続',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 12),

                  // QR発行ボタン
                  CardShell(
                    child: Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            style: primaryBtnStyle,
                            onPressed: (connected && !loading)
                                ? _makeStoreQr
                                : null,
                            icon: const Icon(Icons.qr_code_2),
                            label: const Text('店舗QRコード発行'),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 12),

                  // QR表示：中央寄せ + 余白たっぷり
                  if (connected && publicStoreUrl != null)
                    Align(
                      alignment: Alignment.center,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 520),
                        child: CardShell(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                QrImageView(data: publicStoreUrl!, size: 240),
                                const SizedBox(height: 12),
                                SelectableText(
                                  publicStoreUrl!,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Colors.black87,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                OutlinedButton.icon(
                                  style: outlinedBtnStyle,
                                  icon: const Icon(Icons.open_in_new),
                                  label: const Text('開く'),
                                  onPressed: () => launchUrlString(
                                    publicStoreUrl!,
                                    mode: LaunchMode.externalApplication,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
          filterBar,

          const SizedBox(height: 16),

          // 集計 + ランキング（★ここからは Expanded を使わない）
          StreamBuilder<QuerySnapshot>(
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

              final docs = snap.data?.docs ?? [];
              int totalAll = 0, countAll = 0;
              int totalStore = 0, countStore = 0;
              int totalStaff = 0, countStaff = 0;
              final Map<String, StaffAgg> agg = {};

              for (final doc in docs) {
                final d = doc.data() as Map<String, dynamic>;
                final currency =
                    (d['currency'] as String?)?.toUpperCase() ?? 'JPY';
                if (currency != 'JPY') continue;
                final amount = (d['amount'] as num?)?.toInt() ?? 0;

                totalAll += amount;
                countAll += 1;

                final recipient = (d['recipient'] as Map?)
                    ?.cast<String, dynamic>();
                final employeeId =
                    (d['employeeId'] as String?) ??
                    recipient?['employeeId'] as String?;
                final isStaff = (employeeId != null && employeeId.isNotEmpty);

                if (isStaff) {
                  totalStaff += amount;
                  countStaff += 1;
                  final employeeName =
                      (d['employeeName'] as String?) ??
                      (recipient?['employeeName'] as String?) ??
                      'スタッフ';
                  final entry = agg.putIfAbsent(
                    employeeId,
                    () => StaffAgg(name: employeeName),
                  );
                  entry.total += amount;
                  entry.count += 1;
                } else {
                  totalStore += amount;
                  countStore += 1;
                }
              }

              if (docs.isEmpty) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    HomeMetrics(totalYen: 0, count: 0),
                    SizedBox(height: 12),
                    SplitMetricsRow(
                      storeYen: 0,
                      storeCount: 0,
                      staffYen: 0,
                      staffCount: 0,
                    ),
                    SizedBox(height: 16),
                    Text(
                      'スタッフランキング（上位10）',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: Colors.black87,
                      ),
                    ),
                    SizedBox(height: 8),
                    Center(
                      child: Text(
                        'データがありません',
                        style: TextStyle(color: Colors.black87),
                      ),
                    ),
                  ],
                );
              }

              final ranking = agg.entries.toList()
                ..sort((a, b) => b.value.total.compareTo(a.value.total));
              final top10 = ranking.take(10).toList();
              final entries = List.generate(top10.length, (i) {
                final e = top10[i];
                return RankEntry(
                  rank: i + 1,
                  employeeId: e.key,
                  name: e.value.name,
                  amount: e.value.total,
                  count: e.value.count,
                );
              });

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  HomeMetrics(
                    totalYen: totalAll,
                    count: countAll,
                    onTapTotal: _openPeriodPayments, // ← これで合計タップ→遷移
                  ),
                  const SizedBox(height: 12),
                  SplitMetricsRow(
                    storeYen: totalStore,
                    storeCount: countStore,
                    staffYen: totalStaff,
                    staffCount: countStaff,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'スタッフランキング（上位10）',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 8),

                  // 親スクロールに委ねる
                  RankingGrid(
                    tenantId: widget.tenantId,
                    entries: entries,
                    shrinkWrap: true, // ★重要
                    physics: const NeverScrollableScrollPhysics(), // ★重要
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
