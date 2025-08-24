import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:yourpay/fonts/jp_font.dart';
import 'package:yourpay/tenant/store_detail/card_shell.dart';
import 'package:yourpay/tenant/store_detail/home_metrics.dart';
import 'package:yourpay/tenant/store_detail/range_pill.dart';
import 'package:yourpay/tenant/store_detail/rank_entry.dart';
import 'package:yourpay/tenant/store_detail/tabs/period_payment_page.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';

class StoreHomeTab extends StatefulWidget {
  final String tenantId;
  final String? tenantName;
  const StoreHomeTab({super.key, required this.tenantId, this.tenantName});

  @override
  State<StoreHomeTab> createState() => _StoreHomeTabState();
}

// ==== 期間フィルタ（ダッシュボード表示用：今月/先月/任意月/自由指定）====
enum _RangeMode { thisMonth, lastMonth, month, custom }

class _StoreHomeTabState extends State<StoreHomeTab> {
  bool loading = false;

  // ダッシュボードの期間モード
  _RangeMode _mode = _RangeMode.thisMonth;
  DateTime? _selectedMonthStart; // 「月選択」の基準（各月の1日）
  DateTimeRange? _customRange; // 自由指定の期間

  // ===== ユーティリティ =====
  DateTime _firstDayOfMonth(DateTime d) => DateTime(d.year, d.month, 1);
  DateTime _firstDayOfNextMonth(DateTime d) => (d.month == 12)
      ? DateTime(d.year + 1, 1, 1)
      : DateTime(d.year, d.month + 1, 1);

  // プルダウン候補：直近24か月
  List<DateTime> _monthOptions() {
    final now = DateTime.now();
    final cur = _firstDayOfMonth(now);
    return List.generate(24, (i) => DateTime(cur.year, cur.month - i, 1));
  }

  // ===== 金額計算（パーセント & 固定）=====
  int _calcFee(int amount, {num? percent, num? fixed}) {
    final p = ((percent ?? 0)).clamp(0, 100);
    final f = ((fixed ?? 0)).clamp(0, 1e9);
    final percentPart = (amount * p / 100).floor();
    return (percentPart + f.toInt()).clamp(0, amount);
  }

  // ===== ダッシュボード用：範囲ラベル & 範囲境界 =====
  String _rangeLabel() {
    String ym(DateTime d) => '${d.year}/${d.month.toString().padLeft(2, '0')}';
    String ymd(DateTime d) =>
        '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';

    final now = DateTime.now();
    switch (_mode) {
      case _RangeMode.thisMonth:
        final s = _firstDayOfMonth(now);
        return '今月（${ym(s)}）';
      case _RangeMode.lastMonth:
        final s = _firstDayOfMonth(DateTime(now.year, now.month - 1, 1));
        return '先月（${ym(s)}）';
      case _RangeMode.month:
        final s = _selectedMonthStart ?? _firstDayOfMonth(now);
        return '月選択（${ym(s)}）';
      case _RangeMode.custom:
        if (_customRange == null) return '期間指定';
        return '${ymd(_customRange!.start)}〜${ymd(_customRange!.end)}';
    }
  }

  ({DateTime? start, DateTime? endExclusive}) _rangeBounds() {
    final now = DateTime.now();
    switch (_mode) {
      case _RangeMode.thisMonth:
        final s = _firstDayOfMonth(now);
        return (start: s, endExclusive: _firstDayOfNextMonth(s));
      case _RangeMode.lastMonth:
        final s = _firstDayOfMonth(DateTime(now.year, now.month - 1, 1));
        return (start: s, endExclusive: _firstDayOfNextMonth(s));
      case _RangeMode.month:
        final s = _selectedMonthStart ?? _firstDayOfMonth(now);
        return (start: s, endExclusive: _firstDayOfNextMonth(s));
      case _RangeMode.custom:
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

  // 自由指定ピッカー
  Future<void> _pickCustomRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 1),
      initialDateRange:
          _customRange ??
          DateTimeRange(start: DateTime(now.year, now.month, 1), end: now),
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
        _mode = _RangeMode.custom;
        _customRange = picked;
      });
    }
  }

  // 期間に含まれる各「対象月」の翌月25日を列挙
  List<DateTime> _payoutDatesForRange(DateTime start, DateTime endExclusive) {
    final dates = <DateTime>[];
    // start の属する月の1日から、endExclusive の属する月の1日の“手前”まで
    var cur = DateTime(start.year, start.month, 1);
    final endMonth = DateTime(endExclusive.year, endExclusive.month, 1);
    while (cur.isBefore(endMonth)) {
      final isDec = cur.month == 12;
      final y = isDec ? cur.year + 1 : cur.year;
      final m = isDec ? 1 : cur.month + 1;
      dates.add(DateTime(y, m, 25)); // 翌月25日
      // 次の月へ
      cur = DateTime(cur.year, cur.month + 1, 1);
    }
    return dates;
  }

  // ===== PDF：日付フィルターで絞った期間そのままを出力（店舗入金 + スタッフ別）=====
  Future<void> _exportMonthlyReportPdf() async {
    try {
      setState(() => loading = true);

      // 対象期間（フィルターの期間）
      final b = _rangeBounds();
      if (b.start == null || b.endExclusive == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('期間を選択してください（今月/先月/月選択/期間指定）')),
        );
        return;
      }

      String ymd(DateTime d) =>
          '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';
      final periodLabel =
          '${ymd(b.start!)}〜${ymd(b.endExclusive!.subtract(const Duration(days: 1)))}';

      // 手数料設定
      final tSnap = await FirebaseFirestore.instance
          .collection('tenants')
          .doc(widget.tenantId)
          .get();
      final tData = tSnap.data() ?? {};
      final fee = (tData['fee'] as Map?)?.cast<String, dynamic>() ?? const {};
      final store =
          (tData['storeDeduction'] as Map?)?.cast<String, dynamic>() ??
          const {};
      final feePercent = fee['percent'] as num?;
      final feeFixed = fee['fixed'] as num?;
      final storePercent = store['percent'] as num?;
      final storeFixed = store['fixed'] as num?;
      final payoutDates = _payoutDatesForRange(b.start!, b.endExclusive!);
      String ymdFull(DateTime d) =>
          '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';
      final payoutDatesLabel = payoutDates.map(ymdFull).join('、');

      // Firestore 取得（期間・JPY・成功）
      final qs = await FirebaseFirestore.instance
          .collection('tenants')
          .doc(widget.tenantId)
          .collection('tips')
          .where('status', isEqualTo: 'succeeded')
          .where(
            'createdAt',
            isGreaterThanOrEqualTo: Timestamp.fromDate(b.start!),
          )
          .where('createdAt', isLessThan: Timestamp.fromDate(b.endExclusive!))
          .orderBy('createdAt', descending: false)
          .limit(5000)
          .get();

      if (qs.docs.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('対象期間にデータがありません')));
        return;
      }

      // 集計：店舗入金（総チップ − 運営手数料）
      int storeGross = 0, storeFees = 0, storeDeposit = 0;

      // 集計：スタッフ別
      final byStaff = <String, Map<String, dynamic>>{};
      int grandGross = 0, grandFee = 0, grandStore = 0, grandNet = 0;

      for (final doc in qs.docs) {
        final d = doc.data();
        final currency = (d['currency'] as String?)?.toUpperCase() ?? 'JPY';
        if (currency != 'JPY') continue;

        final amount = (d['amount'] as num?)?.toInt() ?? 0;
        if (amount <= 0) continue;

        final appFee = _calcFee(amount, percent: feePercent, fixed: feeFixed);
        final storeCut = _calcFee(
          amount,
          percent: storePercent,
          fixed: storeFixed,
        );

        // 店舗入金（すべて対象）
        storeGross += amount;
        storeFees += appFee;
        storeDeposit += (amount - appFee);

        // スタッフ宛のみスタッフ集計へ
        final rec = (d['recipient'] as Map?)?.cast<String, dynamic>();
        final staffId =
            (d['employeeId'] as String?) ?? (rec?['employeeId'] as String?);
        if (staffId != null && staffId.isNotEmpty) {
          final staffName =
              (d['employeeName'] as String?) ??
              (rec?['employeeName'] as String?) ??
              'スタッフ';

          final net = (amount - appFee - storeCut).clamp(0, amount);
          final ts = d['createdAt'];
          final when = (ts is Timestamp) ? ts.toDate() : DateTime.now();
          final memo = (d['memo'] as String?) ?? '';

          final bucket = byStaff.putIfAbsent(
            staffId,
            () => {
              'name': staffName,
              'rows': <Map<String, dynamic>>[],
              'gross': 0,
              'fee': 0,
              'store': 0,
              'net': 0,
            },
          );
          (bucket['rows'] as List).add({
            'when': when,
            'gross': amount,
            'fee': appFee,
            'store': storeCut,
            'net': net,
            'memo': memo,
          });
          bucket['gross'] = (bucket['gross'] as int) + amount;
          bucket['fee'] = (bucket['fee'] as int) + appFee;
          bucket['store'] = (bucket['store'] as int) + storeCut;
          bucket['net'] = (bucket['net'] as int) + net;

          grandGross += amount;
          grandFee += appFee;
          grandStore += storeCut;
          grandNet += net;
        }
      }

      // ===== PDF 作成 =====
      final jpTheme = await JpPdfFont.theme();
      final pdf = pw.Document(theme: jpTheme);

      final tenant = widget.tenantName ?? widget.tenantId;
      String yen(int v) => '¥${v.toString()}';
      String fmtDT(DateTime d) =>
          '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')} '
          '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.symmetric(horizontal: 24, vertical: 28),
          header: (ctx) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                '月次チップレポート',
                style: pw.TextStyle(
                  fontSize: 16,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 2),
              pw.Text(
                '店舗: $tenant    対象期間: $periodLabel',
                style: const pw.TextStyle(fontSize: 10),
              ),
              pw.Text(
                '支払予定日: $payoutDatesLabel（毎月25日）',
                style: const pw.TextStyle(fontSize: 10),
              ),
              pw.SizedBox(height: 8),
              pw.Divider(),
            ],
          ),
          build: (ctx) {
            final widgets = <pw.Widget>[];

            // ① 店舗入金（振込見込み）
            widgets.addAll([
              pw.Text(
                '① 店舗入金（見込み）',
                style: pw.TextStyle(
                  fontSize: 13,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 6),
              pw.Table(
                border: pw.TableBorder.all(
                  color: PdfColors.grey500,
                  width: 0.7,
                ),
                columnWidths: const {
                  0: pw.FlexColumnWidth(2),
                  1: pw.FlexColumnWidth(2),
                },
                children: [
                  _trSummary('対象期間チップ総額', yen(storeGross)),
                  _trSummary('運営手数料（合計）', yen(storeFees)),
                  _trSummary('店舗受取見込み（総額 − 手数料）', yen(storeDeposit)),
                ],
              ),
              pw.SizedBox(height: 14),
              pw.Divider(),
            ]);

            // ② スタッフ別支払予定
            if (byStaff.isEmpty) {
              widgets.add(
                pw.Padding(
                  padding: const pw.EdgeInsets.only(top: 8),
                  child: pw.Text('スタッフ宛のチップは対象期間にありません。'),
                ),
              );
            } else {
              widgets.addAll([
                pw.Text(
                  '② スタッフ別支払予定',
                  style: pw.TextStyle(
                    fontSize: 13,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
                pw.SizedBox(height: 6),
              ]);

              final staffEntries = byStaff.entries.toList()
                ..sort(
                  (a, b) =>
                      (b.value['net'] as int).compareTo(a.value['net'] as int),
                );

              for (final e in staffEntries) {
                final name = e.value['name'] as String;
                final rows = (e.value['rows'] as List)
                    .cast<Map<String, dynamic>>();
                rows.sort(
                  (a, b) =>
                      (a['when'] as DateTime).compareTo(b['when'] as DateTime),
                );

                widgets.addAll([
                  pw.SizedBox(height: 10),
                  pw.Text(
                    '■ $name',
                    style: pw.TextStyle(
                      fontSize: 12,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  pw.SizedBox(height: 6),
                  pw.Table(
                    border: pw.TableBorder.symmetric(
                      inside: const pw.BorderSide(
                        color: PdfColors.grey300,
                        width: 0.5,
                      ),
                      outside: const pw.BorderSide(
                        color: PdfColors.grey500,
                        width: 0.7,
                      ),
                    ),
                    columnWidths: const {
                      0: pw.FlexColumnWidth(2), // 日時
                      1: pw.FlexColumnWidth(1), // 実額
                      2: pw.FlexColumnWidth(1), // 運営手数料
                      3: pw.FlexColumnWidth(1), // 店舗控除
                      4: pw.FlexColumnWidth(1), // 受取
                      5: pw.FlexColumnWidth(2), // メモ
                    },
                    children: [
                      pw.TableRow(
                        decoration: const pw.BoxDecoration(
                          color: PdfColors.grey200,
                        ),
                        children: [
                          _cell('日時', bold: true),
                          _cell('実額', bold: true, alignRight: true),
                          _cell('運営手数料', bold: true, alignRight: true),
                          _cell('店舗控除', bold: true, alignRight: true),
                          _cell('受取額', bold: true, alignRight: true),
                          _cell('メモ', bold: true),
                        ],
                      ),
                      ...rows.map((r) {
                        final dt = r['when'] as DateTime;
                        return pw.TableRow(
                          children: [
                            _cell(fmtDT(dt)),
                            _cell(yen(r['gross'] as int), alignRight: true),
                            _cell(yen(r['fee'] as int), alignRight: true),
                            _cell(yen(r['store'] as int), alignRight: true),
                            _cell(yen(r['net'] as int), alignRight: true),
                            _cell((r['memo'] as String?) ?? ''),
                          ],
                        );
                      }),
                    ],
                  ),
                  pw.Align(
                    alignment: pw.Alignment.centerRight,
                    child: pw.Container(
                      margin: const pw.EdgeInsets.only(top: 6),
                      padding: const pw.EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: const pw.BoxDecoration(
                        color: PdfColors.grey200,
                      ),
                      child: pw.Text(
                        '小計  実額: ${yen(e.value['gross'] as int)}   手数料: ${yen(e.value['fee'] as int)}   '
                        '店舗控除: ${yen(e.value['store'] as int)}   受取額: ${yen(e.value['net'] as int)}',
                        style: const pw.TextStyle(fontSize: 10),
                      ),
                    ),
                  ),
                ]);
              }

              widgets.addAll([
                pw.SizedBox(height: 14),
                pw.Divider(),
                pw.Align(
                  alignment: pw.Alignment.centerRight,
                  child: pw.Text(
                    '（スタッフ宛）総計  実額: ${yen(grandGross)}   手数料: ${yen(grandFee)}   '
                    '店舗控除: ${yen(grandStore)}   受取額: ${yen(grandNet)}',
                    style: pw.TextStyle(
                      fontSize: 12,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                ),
              ]);
            }

            return widgets;
          },
        ),
      );

      // 保存（Webはダウンロード、モバイルは共有）
      String ymdFile(DateTime d) =>
          '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';
      final fname =
          'monthly_report_${ymdFile(b.start!)}_to_${ymdFile(b.endExclusive!.subtract(const Duration(days: 1)))}.pdf';
      await Printing.sharePdf(bytes: await pdf.save(), filename: fname);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  // ===== PDFセル & サマリー行 =====
  pw.Widget _cell(String text, {bool bold = false, bool alignRight = false}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: pw.Align(
        alignment: alignRight
            ? pw.Alignment.centerRight
            : pw.Alignment.centerLeft,
        child: pw.Text(
          text,
          style: pw.TextStyle(
            fontSize: 9,
            fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
          ),
        ),
      ),
    );
  }

  pw.TableRow _trSummary(String left, String right) => pw.TableRow(
    children: [_cell(left, bold: true), _cell(right, alignRight: true)],
  );

  // 期間付きの履歴ページへ遷移
  void _openPeriodPayments() {
    final b = _rangeBounds();
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

  @override
  Widget build(BuildContext context) {
    final months = _monthOptions();
    final monthValue = _selectedMonthStart ?? months.first;

    // === フィルタ + PDF をひとつのバーに統合 ===
    final filterBar = Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            RangePill(
              label: '今月',
              active: _mode == _RangeMode.thisMonth,
              onTap: () => setState(() => _mode = _RangeMode.thisMonth),
            ),
            RangePill(
              label: '先月',
              active: _mode == _RangeMode.lastMonth,
              onTap: () => setState(() => _mode = _RangeMode.lastMonth),
            ),
            // 月選択（黒文字/白背景/表示は常に「月選択」）
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: Colors.black26),
                borderRadius: BorderRadius.circular(999),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<DateTime>(
                  value: monthValue,
                  isDense: true,
                  dropdownColor: Colors.white,
                  icon: const Icon(
                    Icons.expand_more,
                    color: Colors.black87,
                    size: 18,
                  ),
                  style: const TextStyle(color: Colors.black87),
                  selectedItemBuilder: (context) => months.map((_) {
                    return const Text(
                      '月選択',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.black87,
                        fontWeight: FontWeight.w700,
                      ),
                    );
                  }).toList(),
                  items: months.map((m) {
                    final label =
                        '${m.year}/${m.month.toString().padLeft(2, '0')}';
                    return DropdownMenuItem<DateTime>(
                      value: m,
                      child: Text(
                        label,
                        style: const TextStyle(color: Colors.black87),
                      ),
                    );
                  }).toList(),
                  onChanged: (val) {
                    if (val == null) return;
                    setState(() {
                      _mode = _RangeMode.month;
                      _selectedMonthStart = val;
                    });
                  },
                ),
              ),
            ),
            RangePill(
              label: _mode == _RangeMode.custom ? _rangeLabel() : '期間指定',
              active: _mode == _RangeMode.custom,
              icon: Icons.date_range,
              onTap: _pickCustomRange,
            ),
            // コンパクトPDFボタン
            FilledButton.icon(
              onPressed: loading ? null : _exportMonthlyReportPdf,
              icon: loading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.picture_as_pdf, size: 18),
              label: const Text('明細PDF'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                backgroundColor: Colors.black,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    // 期間境界で tips クエリ（ストリーム表示用）
    final bounds = _rangeBounds();
    Query tipsQ = FirebaseFirestore.instance
        .collection('tenants')
        .doc(widget.tenantId)
        .collection('tips')
        .where('status', isEqualTo: 'succeeded');
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
          filterBar,
          // ===== ダッシュボード（合計・分割・ランキング）=====
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
                    onTapTotal: _openPeriodPayments,
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
                  RankingGrid(
                    tenantId: widget.tenantId,
                    entries: entries,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
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
