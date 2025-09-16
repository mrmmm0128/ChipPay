import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:yourpay/appadmin/admin_announsment.dart';
import 'package:yourpay/appadmin/tenant/tenant_list_view.dart';
import 'package:yourpay/appadmin/util.dart';

enum AdminViewMode { tenants, agencies }

enum AgenciesTab { agents }

/// 運営ダッシュボード（トップ → 店舗詳細）
class AdminDashboardHome extends StatefulWidget {
  const AdminDashboardHome({super.key});

  @override
  State<AdminDashboardHome> createState() => _AdminDashboardHomeState();
}

class _AdminDashboardHomeState extends State<AdminDashboardHome> {
  final _searchCtrl = TextEditingController();
  String _query = '';
  DatePreset _preset = DatePreset.thisMonth;
  DateTimeRange? _customRange;

  bool _filterActiveOnly = false;
  bool _filterChargesEnabledOnly = false;

  SortBy _sortBy = SortBy.revenueDesc;

  // tenantId -> (sum, count) キャッシュ
  final Map<String, Revenue> _revCache = {};
  DateTime? _rangeStart, _rangeEndEx;

  AdminViewMode _viewMode = AdminViewMode.tenants;
  AgenciesTab agenciesTab = AgenciesTab.agents;

  @override
  void initState() {
    super.initState();
    _applyPreset(); // 初期の期間をセット
    _searchCtrl.addListener(() {
      setState(() => _query = _searchCtrl.text.trim());
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  // 代理店作成ダイアログ
  Future<void> _createAgencyDialog() async {
    final name = TextEditingController();
    final email = TextEditingController();
    final code = TextEditingController();
    final percent = TextEditingController(text: '10');

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: Colors.black),
        ),
        titleTextStyle: const TextStyle(
          color: Colors.black,
          fontSize: 18,
          fontWeight: FontWeight.w700,
        ),
        contentTextStyle: const TextStyle(color: Colors.black),

        title: const Text('代理店を作成'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                decoration: const InputDecoration(
                  labelText: '代理店名 *',
                  border: OutlineInputBorder(),
                ),
                controller: name,
              ),
              const SizedBox(height: 8),
              TextField(
                decoration: const InputDecoration(
                  labelText: 'メール',
                  border: OutlineInputBorder(),
                ),
                controller: email,
              ),
              const SizedBox(height: 8),
              TextField(
                decoration: const InputDecoration(
                  labelText: '紹介コード',
                  border: OutlineInputBorder(),
                ),
                controller: code,
              ),
              const SizedBox(height: 8),
              TextField(
                decoration: const InputDecoration(
                  labelText: '手数料 %',
                  border: OutlineInputBorder(),
                ),
                controller: percent,
                keyboardType: TextInputType.number,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Colors.black, // 文字色
              overlayColor: Colors.black12, // 押下時の波紋色も黒系に
            ),
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.black, // 背景
              foregroundColor: Colors.white, // 文字色
              overlayColor: Colors.white12, // 押下時の波紋
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: const BorderSide(color: Colors.black),
              ),
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('作成'),
          ),
        ],
      ),
    );

    if (ok == true) {
      final p = int.tryParse(percent.text.trim()) ?? 0;
      final now = FieldValue.serverTimestamp();
      await FirebaseFirestore.instance.collection('agencies').add({
        'name': name.text.trim(),
        'email': email.text.trim(),
        'code': code.text.trim(),
        'commissionPercent': p,
        'status': 'active',
        'createdAt': now,
        'updatedAt': now,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('作成しました')));
    }
  }

  // ====== 期間プリセット ======
  void _applyPreset() {
    final now = DateTime.now();
    DateTime start, endEx;

    switch (_preset) {
      case DatePreset.today:
        start = DateTime(now.year, now.month, now.day);
        endEx = start.add(const Duration(days: 1));
        break;
      case DatePreset.yesterday:
        endEx = DateTime(now.year, now.month, now.day);
        start = endEx.subtract(const Duration(days: 1));
        break;
      case DatePreset.thisMonth:
        start = DateTime(now.year, now.month, 1);
        endEx = DateTime(now.year, now.month + 1, 1);
        break;
      case DatePreset.lastMonth:
        final firstThis = DateTime(now.year, now.month, 1);
        endEx = firstThis;
        start = DateTime(firstThis.year, firstThis.month - 1, 1);
        break;
      case DatePreset.custom:
        if (_customRange != null) {
          start = DateTime(
            _customRange!.start.year,
            _customRange!.start.month,
            _customRange!.start.day,
          );
          endEx = DateTime(
            _customRange!.end.year,
            _customRange!.end.month,
            _customRange!.end.day,
          ).add(const Duration(days: 1));
        } else {
          // デフォルトは今月
          start = DateTime(now.year, now.month, 1);
          endEx = DateTime(now.year, now.month + 1, 1);
        }
        break;
    }

    setState(() {
      _rangeStart = start;
      _rangeEndEx = endEx;
      _revCache.clear(); // 期間が変わったらキャッシュは捨てる
    });
  }

  Future<void> _pickCustomRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 2),
      lastDate: DateTime(now.year + 2, 12, 31),
      initialDateRange:
          _customRange ??
          DateTimeRange(
            start: DateTime(now.year, now.month, 1),
            end: DateTime(now.year, now.month, now.day),
          ),
    );
    if (picked != null) {
      setState(() {
        _preset = DatePreset.custom;
        _customRange = picked;
      });
      _applyPreset();
    }
  }

  // ====== 単テナントの売上合計を読み取り（キャッシュ付き） ======
  Future<Revenue> _loadRevenueForTenant({
    required String tenantId,
    required String ownerUid,
  }) async {
    final key =
        '${tenantId}_${_rangeStart?.millisecondsSinceEpoch}_${_rangeEndEx?.millisecondsSinceEpoch}';
    if (_revCache.containsKey(key)) return _revCache[key]!;

    if (_rangeStart == null || _rangeEndEx == null) {
      final none = const Revenue(sum: 0, count: 0);
      _revCache[key] = none;
      return none;
    }

    final qs = await FirebaseFirestore.instance
        .collection(ownerUid)
        .doc(tenantId)
        .collection('tips')
        .where('status', isEqualTo: 'succeeded')
        .where(
          'createdAt',
          isGreaterThanOrEqualTo: Timestamp.fromDate(_rangeStart!),
        )
        .where('createdAt', isLessThan: Timestamp.fromDate(_rangeEndEx!))
        .limit(5000) // 運用に応じて適宜分割
        .get();

    int sum = 0;
    for (final d in qs.docs) {
      final m = d.data();
      final cur = (m['currency'] as String?)?.toUpperCase() ?? 'JPY';
      if (cur != 'JPY') continue;
      final v = (m['amount'] as num?)?.toInt() ?? 0;
      if (v > 0) sum += v;
    }

    final data = Revenue(sum: sum, count: qs.docs.length);
    _revCache[key] = data;
    return data;
  }

  // ====== 表示フォーマット ======
  String _yen(int v) => '¥${v.toString()}';
  String _ymd(DateTime d) =>
      '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final pageTheme = Theme.of(context).copyWith(
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        labelStyle: TextStyle(color: Colors.black),
        hintStyle: TextStyle(color: Colors.black54),
        border: OutlineInputBorder(borderSide: BorderSide(color: Colors.black)),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: Colors.black54),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: Colors.black, width: 2),
        ),
      ),
      dropdownMenuTheme: const DropdownMenuThemeData(
        textStyle: TextStyle(color: Colors.black),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
        ),
      ),

      useMaterial3: true,
      // ベース色
      colorScheme: const ColorScheme.light(
        primary: Colors.black,
        onPrimary: Colors.white,
        secondary: Colors.black,
        onSecondary: Colors.white,
        surface: Colors.white,
        onSurface: Colors.black,
        background: Colors.white,
        onBackground: Colors.black,
      ),
      scaffoldBackgroundColor: Colors.white,

      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
      ),

      dividerTheme: const DividerThemeData(
        color: Colors.black12,
        thickness: 1,
        space: 1,
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
            side: const BorderSide(color: Colors.black),
          ),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
            side: const BorderSide(color: Colors.black),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: Colors.black),
      ),

      // Chip（FilterChip/ChoiceChip）も白黒
      chipTheme: ChipThemeData(
        backgroundColor: Colors.white,
        selectedColor: Colors.black,
        disabledColor: Colors.white,
        checkmarkColor: Colors.white,
        labelStyle: const TextStyle(color: Colors.black),
        secondaryLabelStyle: const TextStyle(color: Colors.white),
        side: const BorderSide(color: Colors.black),
        shape: const StadiumBorder(),
      ),

      // SegmentedButton を白黒
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: MaterialStateProperty.resolveWith(
            (s) => s.contains(MaterialState.selected)
                ? Colors.black
                : Colors.white,
          ),
          foregroundColor: MaterialStateProperty.resolveWith(
            (s) => s.contains(MaterialState.selected)
                ? Colors.white
                : Colors.black,
          ),
          side: MaterialStateProperty.all(
            const BorderSide(color: Colors.black),
          ),
          shape: MaterialStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
      ),
    );

    return Theme(
      data: pageTheme,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('運営ダッシュボード'),
          actions: [
            IconButton(
              tooltip: '再読込',
              onPressed: () => setState(() => _revCache.clear()),
              icon: const Icon(Icons.refresh),
            ),
            IconButton(
              tooltip: 'お知らせ配信',
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const AdminAnnouncementPage(),
                  ),
                );
              },
              icon: const Icon(Icons.campaign_outlined),
            ),
            IconButton(
              tooltip: '再読込',
              onPressed: () => setState(() => _revCache.clear()),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: Column(
          children: [
            Filters(
              searchCtrl: _searchCtrl,
              preset: _preset,
              onPresetChanged: (p) {
                setState(() => _preset = p);
                if (p == DatePreset.custom) {
                  _pickCustomRange();
                } else {
                  _applyPreset();
                }
              },
              rangeStart: _rangeStart,
              rangeEndEx: _rangeEndEx,
              activeOnly: _filterActiveOnly,
              onToggleActive: (v) {
                setState(() => _filterActiveOnly = v);
              },
              chargesEnabledOnly: _filterChargesEnabledOnly,
              onToggleCharges: (v) {
                setState(() => _filterChargesEnabledOnly = v);
              },
              sortBy: _sortBy,
              onSortChanged: (s) => setState(() => _sortBy = s),
            ),

            // ▼ 検索バーのちょい下：ビュー切り替え（店舗一覧 / 代理店）
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: SegmentedButton<AdminViewMode>(
                      segments: const [
                        ButtonSegment(
                          value: AdminViewMode.tenants,
                          label: Text('店舗一覧'),
                        ),
                        ButtonSegment(
                          value: AdminViewMode.agencies,
                          label: Text('代理店'),
                        ),
                      ],
                      selected: {_viewMode},
                      onSelectionChanged: (s) =>
                          setState(() => _viewMode = s.first),
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (_viewMode == AdminViewMode.agencies)
                    FilledButton.icon(
                      onPressed: _createAgencyDialog,
                      icon: const Icon(Icons.add),
                      label: const Text('代理店を追加'),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _viewMode == AdminViewMode.tenants
                  ? TenantsListView(
                      query: _query,
                      filterActiveOnly: _filterActiveOnly,
                      filterChargesEnabledOnly: _filterChargesEnabledOnly,
                      sortBy: _sortBy,
                      rangeStart: _rangeStart,
                      rangeEndEx: _rangeEndEx,
                      loadRevenueForTenant: _loadRevenueForTenant,
                      yen: _yen,
                      ymd: _ymd,
                    )
                  : AgenciesView(
                      query: _query,
                      tab: agenciesTab,
                      onTabChanged: (t) => setState(() => agenciesTab = t),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
