import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'package:yourpay/fonts/jp_font.dart';
import 'package:yourpay/tenant/widget/card_shell.dart';
import 'package:yourpay/tenant/widget/home_metrics.dart';
import 'package:yourpay/tenant/widget/range_pill.dart';
import 'package:yourpay/tenant/widget/rank_entry.dart';
import 'package:yourpay/tenant/widget/period_payment_page.dart';
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

// ==== 期間フィルタ：今日/昨日/今月/先月/任意月/自由指定 ====
enum _RangeMode { today, yesterday, thisMonth, lastMonth, month, custom }

class _StoreHomeTabState extends State<StoreHomeTab> {
  bool loading = false;

  // 期間モード
  _RangeMode _mode = _RangeMode.thisMonth;
  DateTime? _selectedMonthStart; // 「月選択」の各月1日
  DateTimeRange? _customRange; // 自由指定

  // 除外するスタッフ（チップの集計・ランキング・PDFから外す）
  final Set<String> _excludedStaff = <String>{};

  // ===== ユーティリティ =====
  DateTime _firstDayOfMonth(DateTime d) => DateTime(d.year, d.month, 1);
  DateTime _firstDayOfNextMonth(DateTime d) => (d.month == 12)
      ? DateTime(d.year + 1, 1, 1)
      : DateTime(d.year, d.month + 1, 1);

  List<DateTime> _monthOptions() {
    final now = DateTime.now();
    final cur = _firstDayOfMonth(now);
    return List.generate(24, (i) => DateTime(cur.year, cur.month - i, 1));
  }

  int _calcFee(int amount, {num? percent, num? fixed}) {
    final p = ((percent ?? 0)).clamp(0, 100);
    final f = ((fixed ?? 0)).clamp(0, 1e9);
    final percentPart = (amount * p / 100).floor();
    return (percentPart + f.toInt()).clamp(0, amount);
  }

  final uid = FirebaseAuth.instance.currentUser?.uid;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _maybeShowCreatedTenantToast(),
    );
  }

  Future<void> _maybeShowCreatedTenantToast() async {
    final uri = Uri.base;
    final frag =
        uri.fragment; // 例: "/?toast=tenant_created&tenant=xxx&name=YYY"
    final qi = frag.indexOf('?');
    final qp = <String, String>{}..addAll(uri.queryParameters);
    if (qi >= 0) qp.addAll(Uri.splitQueryString(frag.substring(qi + 1)));

    if (qp['toast'] != 'tenant_created') return;

    String name = qp['name'] ?? '';
    final tid = qp['tenant'];
    if (name.isEmpty && tid != null && tid.isNotEmpty) {
      try {
        final doc = await FirebaseFirestore.instance
            .collection(uid!)
            .doc(tid)
            .get();
        name = (doc.data()?['name'] as String?) ?? '';
      } catch (_) {}
    }

    final msg = name.isNotEmpty ? '$name のサブスクリプションを登録しました' : '店舗を作成しました';
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: TextStyle(fontFamily: 'LINEseed')),
      ),
    );

    // （任意）URLの一度きりパラメータを消しておく → Webのみ使うならコメントアウト外す
    // try {
    //   final clean = '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}/#/';
    //   html.window.history.replaceState(null, '', clean);
    // } catch (_) {}
  }

  String _rangeLabel() {
    String ym(DateTime d) => '${d.year}/${d.month.toString().padLeft(2, '0')}';
    String ymd(DateTime d) =>
        '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';

    final now = DateTime.now();
    final today0 = DateTime(now.year, now.month, now.day);
    switch (_mode) {
      case _RangeMode.today:
        return '今日（${ymd(today0)}）';
      case _RangeMode.yesterday:
        final yst = today0.subtract(const Duration(days: 1));
        return '昨日（${ymd(yst)}）';
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
    final today0 = DateTime(now.year, now.month, now.day);
    switch (_mode) {
      case _RangeMode.today:
        return (
          start: today0,
          endExclusive: today0.add(const Duration(days: 1)),
        );
      case _RangeMode.yesterday:
        final s = today0.subtract(const Duration(days: 1));
        return (start: s, endExclusive: today0);
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
    var cur = DateTime(start.year, start.month, 1);
    final endMonth = DateTime(endExclusive.year, endExclusive.month, 1);
    while (cur.isBefore(endMonth)) {
      final isDec = cur.month == 12;
      final y = isDec ? cur.year + 1 : cur.year;
      final m = isDec ? 1 : cur.month + 1;
      dates.add(DateTime(y, m, 25)); // 翌月25日
      cur = DateTime(cur.year, cur.month + 1, 1);
    }
    return dates;
  }

  // ===== PDF（現在の期間＆“除外されていない”スタッフのみ反映）=====
  Future<void> _exportMonthlyReportPdf() async {
    try {
      setState(() => loading = true);

      final b = _rangeBounds();
      if (b.start == null || b.endExclusive == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('期間を選択してください（今日/昨日/今月/先月/月選択/期間指定）')),
        );
        return;
      }

      String ymd(DateTime d) =>
          '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';
      final periodLabel =
          '${ymd(b.start!)}〜${ymd(b.endExclusive!.subtract(const Duration(days: 1)))}';

      // 現行の手数料設定（古いレコードのフォールバック用）
      final tSnap = await FirebaseFirestore.instance
          .collection(uid!)
          .doc(widget.tenantId)
          .get();
      final tData = tSnap.data() ?? {};
      final feeCfg =
          (tData['fee'] as Map?)?.cast<String, dynamic>() ?? const {};
      final storeCfg =
          (tData['storeDeduction'] as Map?)?.cast<String, dynamic>() ??
          const {};
      final feePercent = feeCfg['percent'] as num?;
      final feeFixed = feeCfg['fixed'] as num?;
      final storePercent = storeCfg['percent'] as num?;
      final storeFixed = storeCfg['fixed'] as num?;

      final payoutDates = _payoutDatesForRange(b.start!, b.endExclusive!);
      String ymdFull(DateTime d) =>
          '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';
      final payoutDatesLabel = payoutDates.map(ymdFull).join('、');

      // 期間の Tips を取得
      final qs = await FirebaseFirestore.instance
          .collection(uid!)
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

      // Stripe手数料の推定（保存が無い古いレコード用）
      int _estimateStripeFee(int v) {
        // 2.4%（小数切り捨て）
        return (v * 24) ~/ 1000;
      }

      // 集計
      int totalGross = 0; // 全体の実額合計
      int totalAppFee = 0; // プラットフォーム手数料合計
      int totalStripeFee = 0; // Stripe手数料合計
      int totalStoreNet = 0; // 店舗受取見込み（net.toStore）の合計
      bool anyStripeEstimated = false;

      final byStaff = <String, Map<String, dynamic>>{};
      int grandGross = 0,
          grandAppFee = 0,
          grandStripe = 0,
          grandStore = 0,
          grandNet = 0;

      for (final doc in qs.docs) {
        final d = doc.data();
        final currency = (d['currency'] as String?)?.toUpperCase() ?? 'JPY';
        if (currency != 'JPY') continue;

        final amount = (d['amount'] as num?)?.toInt() ?? 0;
        if (amount <= 0) continue;

        // プラットフォーム手数料（保存優先: fees.platform or appFee -> 無ければ現行設定で算出）
        final feesMap = (d['fees'] as Map?)?.cast<String, dynamic>();
        final appFeeStored =
            (feesMap?['platform'] as num?)?.toInt() ??
            (d['appFee'] as num?)?.toInt();
        final appFee =
            appFeeStored ??
            _calcFee(amount, percent: feePercent, fixed: feeFixed);

        // Stripe手数料（保存があればそれを使用／無ければ推定2.4%）
        final stripeFeeStored =
            ((feesMap?['stripe'] as Map?)?['amount'] as num?)?.toInt();
        final stripeFee = stripeFeeStored ?? _estimateStripeFee(amount);
        if (stripeFeeStored == null) anyStripeEstimated = true;

        // 店舗控除（split.storeAmount -> applied値 -> 現行設定）
        final split = (d['split'] as Map?)?.cast<String, dynamic>();
        int storeCut;
        if (split != null) {
          final storeAmount = (split['storeAmount'] as num?)?.toInt();
          if (storeAmount != null) {
            storeCut = storeAmount;
          } else {
            final pApplied = (split['percentApplied'] as num?)?.toDouble();
            final fApplied = (split['fixedApplied'] as num?)?.toDouble();
            storeCut = _calcFee(amount, percent: pApplied, fixed: fApplied);
          }
        } else {
          storeCut = _calcFee(amount, percent: storePercent, fixed: storeFixed);
        }

        // 受取先（スタッフ/店舗）
        final rec = (d['recipient'] as Map?)?.cast<String, dynamic>();
        final staffId =
            (d['employeeId'] as String?) ?? (rec?['employeeId'] as String?);
        final isStaff = staffId != null && staffId.isNotEmpty;

        // 保存済みのnet（あれば優先）
        final netMap = (d['net'] as Map?)?.cast<String, dynamic>();
        final netToStoreSaved = (netMap?['toStore'] as num?)?.toInt();
        final netToStaffSaved = (netMap?['toStaff'] as num?)?.toInt();

        final netToStore =
            netToStoreSaved ??
            (isStaff
                ? storeCut
                : (amount - appFee - stripeFee).clamp(0, amount));
        final netToStaff =
            netToStaffSaved ??
            (isStaff
                ? (amount - appFee - stripeFee - storeCut).clamp(0, amount)
                : 0);

        // 店舗サマリ（除外スタッフは含めない）
        final include = !isStaff || !_excludedStaff.contains(staffId);
        if (include) {
          totalGross += amount;
          totalAppFee += appFee;
          totalStripeFee += stripeFee;
          totalStoreNet += netToStore;
        }

        // スタッフ別（スタッフのみ & 除外していない）
        if (isStaff && !_excludedStaff.contains(staffId)) {
          final staffName =
              (d['employeeName'] as String?) ??
              (rec?['employeeName'] as String?) ??
              'スタッフ';

          final ts = d['createdAt'];
          final when = (ts is Timestamp) ? ts.toDate() : DateTime.now();
          final memo = (d['memo'] as String?) ?? '';

          final bucket = byStaff.putIfAbsent(
            staffId,
            () => {
              'name': staffName,
              'rows': <Map<String, dynamic>>[],
              'gross': 0,
              'appFee': 0,
              'stripe': 0,
              'store': 0,
              'net': 0,
            },
          );

          (bucket['rows'] as List).add({
            'when': when,
            'gross': amount,
            'appFee': appFee,
            'stripe': stripeFee,
            'store': storeCut,
            'net': netToStaff,
            'memo': memo,
          });

          bucket['gross'] = (bucket['gross'] as int) + amount;
          bucket['appFee'] = (bucket['appFee'] as int) + appFee;
          bucket['stripe'] = (bucket['stripe'] as int) + stripeFee;
          bucket['store'] = (bucket['store'] as int) + storeCut;
          bucket['net'] = (bucket['net'] as int) + netToStaff;

          grandGross += amount;
          grandAppFee += appFee;
          grandStripe += stripeFee;
          grandStore += storeCut;
          grandNet += netToStaff;
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
              if (anyStripeEstimated)
                pw.Padding(
                  padding: const pw.EdgeInsets.only(top: 4),
                  child: pw.Text(
                    '※ 一部のStripe手数料は2.4%で推定しています（保存がない決済）。',
                    style: const pw.TextStyle(fontSize: 9),
                  ),
                ),
              pw.SizedBox(height: 8),
              pw.Divider(),
            ],
          ),
          build: (ctx) {
            final widgets = <pw.Widget>[];

            // ① 店舗入金（見込み）
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
                  _trSummary('対象期間チップ総額', yen(totalGross)),
                  _trSummary('運営手数料（合計）', yen(totalAppFee)),
                  _trSummary('Stripe手数料（合計）', yen(totalStripeFee)),
                  _trSummary('店舗受取見込み（合計）', yen(totalStoreNet)),
                ],
              ),
              pw.SizedBox(height: 14),
              pw.Divider(),
            ]);

            // ② スタッフ別
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
                      3: pw.FlexColumnWidth(1), // Stripe手数料
                      4: pw.FlexColumnWidth(1), // 店舗控除
                      5: pw.FlexColumnWidth(1), // 受取
                      6: pw.FlexColumnWidth(2), // メモ
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
                          _cell('Stripe手数料', bold: true, alignRight: true),
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
                            _cell(yen(r['appFee'] as int), alignRight: true),
                            _cell(yen(r['stripe'] as int), alignRight: true),
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
                        '小計  実額: ${yen(e.value['gross'] as int)}   '
                        '運営手数料: ${yen(e.value['appFee'] as int)}   '
                        'Stripe手数料: ${yen(e.value['stripe'] as int)}   '
                        '店舗控除: ${yen(e.value['store'] as int)}   '
                        '受取額: ${yen(e.value['net'] as int)}',
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
                    '（スタッフ宛）総計  実額: ${yen(grandGross)}   '
                    '運営手数料: ${yen(grandAppFee)}   '
                    'Stripe手数料: ${yen(grandStripe)}   '
                    '店舗控除: ${yen(grandStore)}   '
                    '受取額: ${yen(grandNet)}',
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

  void _openPeriodPayments({RecipientFilter filter = RecipientFilter.all}) {
    final b = _rangeBounds();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PeriodPaymentsPage(
          tenantId: widget.tenantId,
          tenantName: widget.tenantName,
          start: b.start,
          endExclusive: b.endExclusive,
          recipientFilter: filter, // ★ ここ！
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final months = _monthOptions();
    final monthValue = _selectedMonthStart ?? months.first;

    // === 置き換え: 以前の topCta 定義をこれに差し替え ===
    final topCta = Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 左: タイトル
          const Expanded(
            child: Text(
              'チップ売り上げ',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: Colors.black87,
                fontFamily: "LINEseed",
              ),
            ),
          ),
          const SizedBox(width: 12),

          // 右: これまで通りの「明細確認」ボタン（ロジック変更なし）
          Flexible(
            child: Align(
              alignment: Alignment.centerRight,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: FilledButton.icon(
                  onPressed: _exportMonthlyReportPdf,
                  icon: const Icon(Icons.receipt_long, size: 18),
                  // ラベルは少しだけ短くして横幅を節約（処理は同じ）
                  label: const Text('pdf'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                    backgroundColor: Colors.black,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );

    // === フィルタバー ===
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
              label: '今日',
              active: _mode == _RangeMode.today,
              onTap: () => setState(() => _mode = _RangeMode.today),
            ),
            RangePill(
              label: '昨日',
              active: _mode == _RangeMode.yesterday,
              onTap: () => setState(() => _mode = _RangeMode.yesterday),
            ),
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
            // 月選択
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
                  selectedItemBuilder: (context) => months
                      .map(
                        (_) => const Text(
                          '月選択',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.black87,
                            fontWeight: FontWeight.w700,
                            fontFamily: "LINEseed",
                          ),
                        ),
                      )
                      .toList(),
                  items: months
                      .map(
                        (m) => DropdownMenuItem<DateTime>(
                          value: m,
                          child: Text(
                            '${m.year}/${m.month.toString().padLeft(2, '0')}',
                            style: const TextStyle(
                              color: Colors.black87,
                              fontFamily: "LINEseed",
                            ),
                          ),
                        ),
                      )
                      .toList(),
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

              onTap: _pickCustomRange,
            ),
          ],
        ),
      ),
    );

    // 期間境界で tips クエリ（ストリーム）
    final bounds = _rangeBounds();
    Query tipsQ = FirebaseFirestore.instance
        .collection(uid!)
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
          topCta,
          const Text(
            "期間",
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: Colors.black87,
              fontFamily: "LINEseed",
            ),
          ),
          const SizedBox(height: 7),
          filterBar,

          // ===== データ＆UI（スタッフチップ/ランキング/統計） =====
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

              // まず「この期間に現れたスタッフ一覧（全員）」を作る（合計額で並び替え）
              final Map<String, int> staffTotalsAll = {};
              final Map<String, String> staffNamesAll = {};
              for (final doc in docs) {
                final d = doc.data() as Map<String, dynamic>;
                final recipient = (d['recipient'] as Map?)
                    ?.cast<String, dynamic>();
                final employeeId =
                    (d['employeeId'] as String?) ??
                    recipient?['employeeId'] as String?;
                if (employeeId != null && employeeId.isNotEmpty) {
                  final name =
                      (d['employeeName'] as String?) ??
                      (recipient?['employeeName'] as String?) ??
                      'スタッフ';
                  staffNamesAll[employeeId] = name;
                  final amount = (d['amount'] as num?)?.toInt() ?? 0;
                  staffTotalsAll[employeeId] =
                      (staffTotalsAll[employeeId] ?? 0) + amount;
                }
              }
              final staffOrder = staffTotalsAll.keys.toList()
                ..sort(
                  (a, b) => (staffTotalsAll[b] ?? 0).compareTo(
                    staffTotalsAll[a] ?? 0,
                  ),
                );

              // === スタッフ切替ボタン列（除外は暗く） ===
              Widget staffChips() {
                if (staffOrder.isEmpty) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final id in staffOrder)
                        ChoiceChip(
                          label: Text(
                            staffNamesAll[id] ?? 'スタッフ',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: Colors.black87,
                              fontFamily: "LINEseed",
                            ),
                          ),
                          selected: _excludedStaff.contains(
                            id,
                          ), // selected = 除外中（暗く）
                          onSelected: (sel) {
                            setState(() {
                              if (sel) {
                                _excludedStaff.add(id);
                              } else {
                                _excludedStaff.remove(id);
                              }
                            });
                          },
                          selectedColor: Colors.black,
                          labelStyle: TextStyle(
                            color: _excludedStaff.contains(id)
                                ? Colors.white
                                : Colors.black87,
                            fontWeight: FontWeight.w600,
                          ),
                          backgroundColor: Colors.white,
                          shape: StadiumBorder(
                            side: BorderSide(color: Colors.black26),
                          ),
                        ),
                      if (_excludedStaff.isNotEmpty)
                        TextButton(
                          onPressed: () =>
                              setState(() => _excludedStaff.clear()),
                          child: const Text('全員含める'),
                        ),
                    ],
                  ),
                );
              }

              // ==== 集計（除外を反映）====
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

                final recipient = (d['recipient'] as Map?)
                    ?.cast<String, dynamic>();
                final employeeId =
                    (d['employeeId'] as String?) ??
                    recipient?['employeeId'] as String?;
                final isStaff = (employeeId != null && employeeId.isNotEmpty);

                // 除外ロジック：スタッフ分は除外セットに入っていたらスキップ
                final include =
                    !isStaff || !_excludedStaff.contains(employeeId);
                if (!include) continue;

                totalAll += amount;
                countAll += 1;

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

              // === UI ===
              if (docs.isEmpty) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    SizedBox(height: 8),
                    Text(
                      'この期間のデータがありません',
                      style: TextStyle(
                        color: Colors.black87,
                        fontFamily: "LINEseed",
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
                  const Text(
                    "スタッフ",
                    style: TextStyle(
                      color: Colors.black87,
                      fontFamily: "LINEseed",
                    ),
                  ),
                  const SizedBox(height: 10),
                  staffChips(),
                  TotalsCard(
                    totalYen: totalAll,
                    count: countAll,
                    onTap: _openPeriodPayments,
                  ),
                  const SizedBox(height: 12),
                  // 例：SplitMetricsRow の配置箇所
                  SplitMetricsRow(
                    storeYen: totalStore,
                    storeCount: countStore,
                    staffYen: totalStaff,
                    staffCount: countStaff,
                    onTapStore: () => _openPeriodPayments(
                      filter: RecipientFilter.storeOnly, // ★ 店舗のみ
                    ),
                    onTapStaff: () => _openPeriodPayments(
                      filter: RecipientFilter.staffOnly, // ★ スタッフのみ
                    ),
                  ),

                  const SizedBox(height: 24),

                  const Text(
                    'スタッフランキング（上位10）',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: Colors.black87,
                      fontFamily: "LINEseed",
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
