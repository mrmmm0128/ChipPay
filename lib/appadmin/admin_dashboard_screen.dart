import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

enum _AdminViewMode { tenants, agencies }

enum _AgenciesTab { agents }

/// 運営ダッシュボード（トップ → 店舗詳細）
class AdminDashboardHome extends StatefulWidget {
  const AdminDashboardHome({super.key});

  @override
  State<AdminDashboardHome> createState() => _AdminDashboardHomeState();
}

class _AdminDashboardHomeState extends State<AdminDashboardHome> {
  final _searchCtrl = TextEditingController();
  String _query = '';
  _DatePreset _preset = _DatePreset.thisMonth;
  DateTimeRange? _customRange;

  bool _filterActiveOnly = false;
  bool _filterChargesEnabledOnly = false;

  _SortBy _sortBy = _SortBy.revenueDesc;

  // tenantId -> (sum, count) キャッシュ
  final Map<String, _Revenue> _revCache = {};
  DateTime? _rangeStart, _rangeEndEx;

  _AdminViewMode _viewMode = _AdminViewMode.tenants;
  _AgenciesTab _agenciesTab = _AgenciesTab.agents;

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
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
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
      case _DatePreset.today:
        start = DateTime(now.year, now.month, now.day);
        endEx = start.add(const Duration(days: 1));
        break;
      case _DatePreset.yesterday:
        endEx = DateTime(now.year, now.month, now.day);
        start = endEx.subtract(const Duration(days: 1));
        break;
      case _DatePreset.thisMonth:
        start = DateTime(now.year, now.month, 1);
        endEx = DateTime(now.year, now.month + 1, 1);
        break;
      case _DatePreset.lastMonth:
        final firstThis = DateTime(now.year, now.month, 1);
        endEx = firstThis;
        start = DateTime(firstThis.year, firstThis.month - 1, 1);
        break;
      case _DatePreset.custom:
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
        _preset = _DatePreset.custom;
        _customRange = picked;
      });
      _applyPreset();
    }
  }

  // ====== 単テナントの売上合計を読み取り（キャッシュ付き） ======
  Future<_Revenue> _loadRevenueForTenant({
    required String tenantId,
    required String ownerUid,
  }) async {
    final key =
        '${tenantId}_${_rangeStart?.millisecondsSinceEpoch}_${_rangeEndEx?.millisecondsSinceEpoch}';
    if (_revCache.containsKey(key)) return _revCache[key]!;

    if (_rangeStart == null || _rangeEndEx == null) {
      final none = const _Revenue(sum: 0, count: 0);
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

    final data = _Revenue(sum: sum, count: qs.docs.length);
    _revCache[key] = data;
    return data;
  }

  // ====== 表示フォーマット ======
  String _yen(int v) => '¥${v.toString()}';
  String _ymd(DateTime d) =>
      '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('運営ダッシュボード'),
        actions: [
          IconButton(
            tooltip: '再読込',
            onPressed: () => setState(() => _revCache.clear()),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          _Filters(
            searchCtrl: _searchCtrl,
            preset: _preset,
            onPresetChanged: (p) {
              setState(() => _preset = p);
              if (p == _DatePreset.custom) {
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
                  child: SegmentedButton<_AdminViewMode>(
                    segments: const [
                      ButtonSegment(
                        value: _AdminViewMode.tenants,
                        label: Text('店舗一覧'),
                      ),
                      ButtonSegment(
                        value: _AdminViewMode.agencies,
                        label: Text('代理店'),
                      ),
                    ],
                    selected: {_viewMode},
                    onSelectionChanged: (s) =>
                        setState(() => _viewMode = s.first),
                  ),
                ),
                const SizedBox(width: 12),
                if (_viewMode == _AdminViewMode.agencies)
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
            child: _viewMode == _AdminViewMode.tenants
                ? _TenantsListView(
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
                : _AgenciesView(
                    query: _query,
                    tab: _agenciesTab,
                    onTabChanged: (t) => setState(() => _agenciesTab = t),
                  ),
          ),
        ],
      ),
    );
  }
}

// ======= 店舗行（売上は非同期集計） =======
class _TenantTile extends StatefulWidget {
  final String tenantId;
  final String ownerUid;
  final String name;
  final String status;
  final String plan;
  final bool chargesEnabled;
  final DateTime? createdAt;
  final String rangeLabel;
  final Future<_Revenue> Function() loadRevenue;
  final VoidCallback onTap;
  final String Function(int) yen;

  // ▼ 追加：サブスク表示用
  final String subPlan;
  final String subStatus;
  final bool subOverdue;
  final DateTime? subNextPaymentAt;

  const _TenantTile({
    required this.tenantId,
    required this.ownerUid,
    required this.name,
    required this.status,
    required this.plan,
    required this.chargesEnabled,
    required this.createdAt,
    required this.rangeLabel,
    required this.loadRevenue,
    required this.onTap,
    required this.yen,
    // 追加分
    required this.subPlan,
    required this.subStatus,
    required this.subOverdue,
    required this.subNextPaymentAt,
    super.key,
  });

  @override
  State<_TenantTile> createState() => _TenantTileState();
}

class _TenantTileState extends State<_TenantTile> {
  _Revenue? _rev;
  bool _loading = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final r = await widget.loadRevenue();
    if (!mounted) return;
    setState(() {
      _rev = r;
      _loading = false;
    });
  }

  String _ymd(DateTime d) =>
      '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final subtitleLines = <String>[
      'ID: ${widget.tenantId}',
      if (widget.plan.isNotEmpty) 'Plan: ${widget.plan}',
      'Status: ${widget.status}${widget.chargesEnabled ? ' / charges_enabled' : ''}',
      // ▼ サブスク要約（プラン / ステータス）
      'Sub: ${widget.subPlan}/${widget.subStatus.toUpperCase()}',
      if (widget.createdAt != null) 'Created: ${widget.createdAt}',
    ];

    final nextLabel = widget.subNextPaymentAt != null
        ? '次回: ${_ymd(widget.subNextPaymentAt!)}'
        : null;

    return ListTile(
      onTap: widget.onTap,
      title: Text(
        widget.name,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(subtitleLines.join('  •  ')),
      trailing: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (_loading)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Text(
              _rev == null ? '—' : widget.yen(_rev!.sum),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          const SizedBox(height: 2),
          if (nextLabel != null)
            Text(
              nextLabel,
              style: const TextStyle(fontSize: 11, color: Colors.black54),
            ),
          if (widget.subOverdue) ...[
            const SizedBox(height: 2),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFFFFEBEE),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: const Color(0xFFB00020).withOpacity(0.25),
                ),
              ),
              child: const Text(
                '未払いあり',
                style: TextStyle(
                  color: Color(0xFFB00020),
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
          const SizedBox(height: 2),
          Text(
            widget.rangeLabel,
            style: const TextStyle(fontSize: 11, color: Colors.black54),
          ),
        ],
      ),
    );
  }
}

// ======= 店舗詳細 =======
class AdminTenantDetailPage extends StatelessWidget {
  final String ownerUid;
  final String tenantId;
  final String tenantName;

  const AdminTenantDetailPage({
    super.key,
    required this.ownerUid,
    required this.tenantId,
    required this.tenantName,
  });

  String _yen(int v) => '¥${v.toString()}';
  String _ymdhm(DateTime d) =>
      '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final tenantRef = FirebaseFirestore.instance
        .collection(ownerUid)
        .doc(tenantId);
    final indexRef = FirebaseFirestore.instance
        .collection('tenantIndex')
        .doc(tenantId);

    return Scaffold(
      appBar: AppBar(title: Text('店舗詳細：$tenantName')),
      body: ListView(
        children: [
          // 基本情報カード
          StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            stream: indexRef.snapshots(),
            builder: (context, snap) {
              final m = snap.data?.data();
              final plan = (m?['subscription']?['plan'] ?? '').toString();
              final status = (m?['status'] ?? '').toString();
              final chargesEnabled = m?['connect']?['charges_enabled'] == true;

              return _Card(
                title: '基本情報',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _kv('Tenant ID', tenantId),
                    _kv('Owner UID', ownerUid),
                    _kv('Name', tenantName),
                    _kv('Plan', plan.isEmpty ? '-' : plan),
                    _kv('Status', status),
                    _kv('Stripe', chargesEnabled ? 'charges_enabled' : '—'),
                  ],
                ),
              );
            },
          ),

          // 登録状況カード
          _StatusCard(tenantId: tenantId),

          // 直近チップ
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: tenantRef
                .collection('tips')
                .where('status', isEqualTo: 'succeeded')
                .orderBy('createdAt', descending: true)
                .limit(50)
                .snapshots(),
            builder: (context, snap) {
              final docs = snap.data?.docs ?? const [];
              return _Card(
                title: '直近のチップ（50件）',
                child: Column(
                  children: docs.isEmpty
                      ? [const ListTile(title: Text('データがありません'))]
                      : docs.map((d) {
                          final m = d.data();
                          final amount = (m['amount'] as num?)?.toInt() ?? 0;
                          final emp = (m['employeeName'] ?? 'スタッフ').toString();
                          final ts = m['createdAt'];
                          final when = (ts is Timestamp) ? ts.toDate() : null;
                          return ListTile(
                            dense: true,
                            title: Text('${_yen(amount)}  /  $emp'),
                            subtitle: Text(when == null ? '-' : _ymdhm(when)),
                            trailing: Text(
                              (m['currency'] ?? 'JPY').toString().toUpperCase(),
                            ),
                          );
                        }).toList(),
                ),
              );
            },
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        SizedBox(
          width: 120,
          child: Text(k, style: const TextStyle(color: Colors.black54)),
        ),
        Expanded(child: Text(v)),
      ],
    ),
  );
}

// ▼ 追加：ステータス表示カード
class _StatusCard extends StatelessWidget {
  final String tenantId;
  const _StatusCard({required this.tenantId});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('tenantIndex')
          .doc(tenantId)
          .snapshots(),
      builder: (context, snap) {
        if (snap.hasError) {
          return _Card(title: '登録状況', child: Text('読込エラー: ${snap.error}'));
        }
        if (!snap.hasData) {
          return const _Card(
            title: '登録状況',
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(8.0),
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }

        final m = snap.data!.data() ?? {};

        // 初期費用
        final initStatus = (m['billing']?['initialFee']?['status'] ?? 'none')
            .toString();
        final initChip = _statusChip(
          label: switch (initStatus) {
            'paid' => '初期費用: 支払い済み',
            'checkout_open' => '初期費用: 決済中',
            _ => '初期費用: 未',
          },
          kind: switch (initStatus) {
            'paid' => _ChipKind.good,
            'checkout_open' => _ChipKind.warn,
            _ => _ChipKind.bad,
          },
        );

        // サブスク
        final subPlan = (m['subscription']?['plan'] ?? '-').toString();
        final subStatus = (m['subscription']?['status'] ?? 'none').toString();
        // 期限：nextPaymentAt 優先、なければ currentPeriodEnd をフォールバック
        final _nextRaw =
            m['subscription']?['nextPaymentAt'] ??
            m['subscription']?['currentPeriodEnd'];
        final nextAt = (_nextRaw is Timestamp) ? _nextRaw.toDate() : null;
        final overdue =
            m['subscription']?['overdue'] == true ||
            subStatus == 'past_due' ||
            subStatus == 'unpaid';

        final subChip = _statusChip(
          label:
              'サブスク: $subPlan / ${subStatus.toUpperCase()}${nextAt != null ? '（次回: ${_ymd(nextAt)}）' : ''}${overdue ? '（未払い）' : ''}',
          kind: overdue
              ? _ChipKind.bad
              : (subStatus == 'active' || subStatus == 'trialing')
              ? _ChipKind.good
              : (subStatus == 'none' ? _ChipKind.bad : _ChipKind.warn),
        );

        // Connect
        final chargesEnabled = m['connect']?['charges_enabled'] == true;
        final payoutsEnabled = m['connect']?['payouts_enabled'] == true;
        final detailsSubmitted = m['connect']?['details_submitted'] == true;
        final currentlyDue =
            (m['connect']?['requirements']?['currently_due'] as List?)
                ?.length ??
            0;

        final connectRows = <Widget>[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _statusChip(
                label: 'details_submitted: ${detailsSubmitted ? 'OK' : '—'}',
                kind: detailsSubmitted ? _ChipKind.good : _ChipKind.warn,
              ),
              _statusChip(
                label: 'charges_enabled: ${chargesEnabled ? 'OK' : '—'}',
                kind: chargesEnabled ? _ChipKind.good : _ChipKind.bad,
              ),
              _statusChip(
                label: 'payouts_enabled: ${payoutsEnabled ? 'OK' : '—'}',
                kind: payoutsEnabled ? _ChipKind.good : _ChipKind.warn,
              ),
              if (currentlyDue > 0)
                _statusChip(
                  label: '要提出: $currentlyDue 件',
                  kind: _ChipKind.warn,
                ),
            ],
          ),
        ];

        return _Card(
          title: '登録状況',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 初期費用
              const Text('初期費用'),
              const SizedBox(height: 4),
              Wrap(spacing: 8, runSpacing: 8, children: [initChip]),
              const SizedBox(height: 12),
              // サブスク
              const Text('サブスクリプション'),
              const SizedBox(height: 4),
              Wrap(spacing: 8, runSpacing: 8, children: [subChip]),
              const SizedBox(height: 12),
              // Connect
              const Text('Stripe Connect'),
              const SizedBox(height: 4),
              ...connectRows,
            ],
          ),
        );
      },
    );
  }

  String _ymd(DateTime d) =>
      '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';

  Widget _statusChip({required String label, required _ChipKind kind}) {
    final color = switch (kind) {
      _ChipKind.good => const Color(0xFF1B5E20),
      _ChipKind.warn => const Color(0xFFB26A00),
      _ChipKind.bad => const Color(0xFFB00020),
    };
    final bg = switch (kind) {
      _ChipKind.good => const Color(0xFFE8F5E9),
      _ChipKind.warn => const Color(0xFFFFF3E0),
      _ChipKind.bad => const Color(0xFFFFEBEE),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.25)),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}

enum _ChipKind { good, warn, bad }

// ====== 小物UI ======
class _Card extends StatelessWidget {
  final String title;
  final Widget child;
  final Widget? action;
  const _Card({required this.title, required this.child, this.action});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                if (action != null) action!,
              ],
            ),
            const Divider(height: 16),
            child,
          ],
        ),
      ),
    );
  }
}

class _Filters extends StatelessWidget {
  final TextEditingController searchCtrl;
  final _DatePreset preset;
  final void Function(_DatePreset) onPresetChanged;
  final DateTime? rangeStart;
  final DateTime? rangeEndEx;
  final bool activeOnly;
  final bool chargesEnabledOnly;
  final ValueChanged<bool> onToggleActive;
  final ValueChanged<bool> onToggleCharges;
  final _SortBy sortBy;
  final ValueChanged<_SortBy> onSortChanged;

  const _Filters({
    required this.searchCtrl,
    required this.preset,
    required this.onPresetChanged,
    required this.rangeStart,
    required this.rangeEndEx,
    required this.activeOnly,
    required this.chargesEnabledOnly,
    required this.onToggleActive,
    required this.onToggleCharges,
    required this.sortBy,
    required this.onSortChanged,
  });

  String _ymd(DateTime d) =>
      '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final rangeLabel = (rangeStart != null && rangeEndEx != null)
        ? '${_ymd(rangeStart!)} 〜 ${_ymd(rangeEndEx!.subtract(const Duration(days: 1)))}'
        : '—';

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          // 検索
          SizedBox(
            width: 240,
            child: TextField(
              controller: searchCtrl,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: '店舗名 / ID 検索',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
          ),
          // 期間プリセット
          DropdownButton<_DatePreset>(
            value: preset,
            onChanged: (v) => v != null ? onPresetChanged(v) : null,
            items: const [
              DropdownMenuItem(value: _DatePreset.today, child: Text('今日')),
              DropdownMenuItem(value: _DatePreset.yesterday, child: Text('昨日')),
              DropdownMenuItem(value: _DatePreset.thisMonth, child: Text('今月')),
              DropdownMenuItem(value: _DatePreset.lastMonth, child: Text('先月')),
              DropdownMenuItem(value: _DatePreset.custom, child: Text('期間指定')),
            ],
          ),
          Text(rangeLabel, style: const TextStyle(color: Colors.black54)),

          // ステータスフィルタ
          FilterChip(
            label: const Text('status: active'),
            selected: activeOnly,
            onSelected: onToggleActive,
          ),
          FilterChip(
            label: const Text('charges_enabled'),
            selected: chargesEnabledOnly,
            onSelected: onToggleCharges,
          ),

          // 並び替え
          const SizedBox(width: 8),
          DropdownButton<_SortBy>(
            value: sortBy,
            onChanged: (v) => v != null ? onSortChanged(v) : null,
            items: const [
              DropdownMenuItem(
                value: _SortBy.revenueDesc,
                child: Text('売上の高い順（表示内／簡易）'),
              ),
              DropdownMenuItem(value: _SortBy.nameAsc, child: Text('店舗名（昇順）')),
              DropdownMenuItem(
                value: _SortBy.createdDesc,
                child: Text('作成日時（新しい順）'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

enum _DatePreset { today, yesterday, thisMonth, lastMonth, custom }

enum _SortBy { revenueDesc, nameAsc, createdDesc }

class _Revenue {
  final int sum;
  final int count;
  const _Revenue({required this.sum, required this.count});
}

class _AgenciesView extends StatelessWidget {
  final String query;
  final _AgenciesTab tab;
  final ValueChanged<_AgenciesTab> onTabChanged;

  const _AgenciesView({
    required this.query,
    required this.tab,
    required this.onTabChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // 代理店ビュー内のサブ切替（必要なら拡張）
        const Divider(height: 1),
        Expanded(child: _AgentsList(query: query)),
      ],
    );
  }
}

// 代理店一覧（タップで代理店詳細ページへ遷移）
class _AgentsList extends StatelessWidget {
  final String query;
  const _AgentsList({required this.query});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('agencies')
          .orderBy('createdAt', descending: true)
          .snapshots(),
      builder: (context, snap) {
        if (snap.hasError) return Center(child: Text('読込エラー: ${snap.error}'));
        if (!snap.hasData)
          return const Center(child: CircularProgressIndicator());

        var docs = snap.data!.docs;
        final q = query.trim().toLowerCase();
        if (q.isNotEmpty) {
          docs = docs.where((d) {
            final m = d.data();
            final name = (m['name'] ?? '').toString().toLowerCase();
            final email = (m['email'] ?? '').toString().toLowerCase();
            final code = (m['code'] ?? '').toString().toLowerCase();
            return name.contains(q) ||
                email.contains(q) ||
                code.contains(q) ||
                d.id.toLowerCase().contains(q);
          }).toList();
        }

        if (docs.isEmpty) return const Center(child: Text('代理店がありません'));

        return ListView.separated(
          itemCount: docs.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, i) {
            final d = docs[i];
            final m = d.data();
            final name = (m['name'] ?? '(no name)').toString();
            final email = (m['email'] ?? '').toString();
            final code = (m['code'] ?? '').toString();
            final percent = (m['commissionPercent'] ?? 0).toString();
            final status = (m['status'] ?? 'active').toString();

            return ListTile(
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => AgencyDetailPage(agentId: d.id),
                    settings: RouteSettings(arguments: {'agentId': d.id}),
                  ),
                );
              },
              leading: const Icon(Icons.apartment),
              title: Text(
                name,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                [
                  if (email.isNotEmpty) email,
                  if (code.isNotEmpty) 'code: $code',
                  '手数料: $percent%',
                  'status: $status',
                ].join('  •  '),
              ),
              trailing: const Icon(Icons.chevron_right),
            );
          },
        );
      },
    );
  }
}

class AgencyDetailPage extends StatelessWidget {
  final String agentId;
  const AgencyDetailPage({super.key, required this.agentId});

  String _ymdhm(DateTime d) =>
      '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final ref = FirebaseFirestore.instance.collection('agencies').doc(agentId);
    final searchCtrl = TextEditingController();

    return Scaffold(
      appBar: AppBar(title: const Text('代理店詳細')),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: ref.snapshots(),
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text('読込エラー: ${snap.error}'));
          if (!snap.hasData)
            return const Center(child: CircularProgressIndicator());

          final m = snap.data!.data() ?? {};
          final name = (m['name'] ?? '(no name)').toString();
          final email = (m['email'] ?? '').toString();
          final code = (m['code'] ?? '').toString();
          final percent = (m['commissionPercent'] ?? 0).toString();
          final status = (m['status'] ?? 'active').toString();
          final createdAt = (m['createdAt'] is Timestamp)
              ? (m['createdAt'] as Timestamp).toDate()
              : null;
          final updatedAt = (m['updatedAt'] is Timestamp)
              ? (m['updatedAt'] as Timestamp).toDate()
              : null;

          return ListView(
            children: [
              ListTile(
                title: Text(
                  name,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Text('Agent ID: $agentId'),
                trailing: IconButton(
                  tooltip: '編集',
                  icon: const Icon(Icons.edit),
                  onPressed: () => _editAgent(context, ref, m),
                ),
              ),
              const Divider(height: 1),
              _kv('メール', email.isNotEmpty ? email : '—'),
              _kv('紹介コード', code.isNotEmpty ? code : '—'),
              _kv('手数料', '$percent%'),
              _kv('ステータス', status),
              if (createdAt != null) _kv('作成', _ymdhm(createdAt)),
              if (updatedAt != null) _kv('更新', _ymdhm(updatedAt)),
              const SizedBox(height: 12),
              const Divider(height: 1),

              // ===== 登録店舗（contracts） =====
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Text(
                  '登録店舗一覧',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),

              // 検索ボックス（tenantName / tenantId / ownerUid などでフィルタ）
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  controller: searchCtrl,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: '店舗名 / tenantId / ownerUid 検索',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => (context as Element).markNeedsBuild(),
                ),
              ),

              _ContractsListForAgent(agentId: agentId),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }

  Future<void> _editAgent(
    BuildContext context,
    DocumentReference<Map<String, dynamic>> ref,
    Map<String, dynamic> current,
  ) async {
    final nameC = TextEditingController(
      text: (current['name'] ?? '').toString(),
    );
    final emailC = TextEditingController(
      text: (current['email'] ?? '').toString(),
    );
    final codeC = TextEditingController(
      text: (current['code'] ?? '').toString(),
    );
    final pctC = TextEditingController(
      text: ((current['commissionPercent'] ?? 0)).toString(),
    );
    String status = (current['status'] ?? 'active').toString();

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('代理店情報を編集'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameC,
                decoration: const InputDecoration(labelText: '名称'),
              ),
              TextField(
                controller: emailC,
                decoration: const InputDecoration(labelText: 'メール'),
              ),
              TextField(
                controller: codeC,
                decoration: const InputDecoration(labelText: '紹介コード'),
              ),
              TextField(
                controller: pctC,
                decoration: const InputDecoration(labelText: '手数料(%)'),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: status,
                items: const [
                  DropdownMenuItem(value: 'active', child: Text('active')),
                  DropdownMenuItem(
                    value: 'suspended',
                    child: Text('suspended'),
                  ),
                ],
                onChanged: (v) => status = v ?? 'active',
                decoration: const InputDecoration(labelText: 'ステータス'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );

    if (ok != true) return;

    final pct = int.tryParse(pctC.text.trim());
    await ref.set({
      'name': nameC.text.trim(),
      'email': emailC.text.trim(),
      'code': codeC.text.trim(),
      if (pct != null) 'commissionPercent': pct,
      'status': status,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Widget _kv(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    child: Row(
      children: [
        SizedBox(
          width: 120,
          child: Text(k, style: const TextStyle(color: Colors.black54)),
        ),
        Expanded(child: Text(v)),
      ],
    ),
  );
}

// 1代理店の contracts を表示（行内で tenantIndex を覗いて簡易ステータス表示）
class _ContractsListForAgent extends StatelessWidget {
  final String agentId;
  const _ContractsListForAgent({required this.agentId});

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
                final subSt = (tm['subscription']?['status'] ?? 'none')
                    .toString();
                final subPl = (tm['subscription']?['plan'] ?? '-').toString();
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
                            : '初期費用:未',
                        init == 'paid'
                            ? _ChipKind.good
                            : (init == 'checkout_open'
                                  ? _ChipKind.warn
                                  : _ChipKind.bad),
                      ),
                      _mini(
                        'サブスク:$subPl/${subSt.toUpperCase()}'
                        '${nextAt != null ? '・次回:${_ymd(nextAt)}' : ''}'
                        '${overdue ? '・未払い' : ''}',
                        overdue
                            ? _ChipKind.bad
                            : (subSt == 'active' || subSt == 'trialing')
                            ? _ChipKind.good
                            : (subSt == 'none'
                                  ? _ChipKind.bad
                                  : _ChipKind.warn),
                      ),
                      _mini(
                        chg ? 'charges_enabled' : 'charges_disabled',
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

class _TenantsListView extends StatelessWidget {
  final String query;
  final bool filterActiveOnly;
  final bool filterChargesEnabledOnly;
  final _SortBy sortBy;
  final DateTime? rangeStart;
  final DateTime? rangeEndEx;
  final Future<_Revenue> Function({
    required String tenantId,
    required String ownerUid,
  })
  loadRevenueForTenant;
  final String Function(int) yen;
  final String Function(DateTime) ymd;

  const _TenantsListView({
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
        if (sortBy == _SortBy.nameAsc) {
          docs.sort(
            (a, b) => (a.data()['name'] ?? '').toString().compareTo(
              (b.data()['name'] ?? '').toString(),
            ),
          );
        } else if (sortBy == _SortBy.createdDesc) {
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

            return _TenantTile(
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
