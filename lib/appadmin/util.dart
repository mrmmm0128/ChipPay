// ▼ 追加：ステータス表示カード
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:yourpay/appadmin/admin_dashboard_screen.dart';
import 'package:yourpay/appadmin/agent/agent_list.dart';

enum DatePreset { today, yesterday, thisMonth, lastMonth, custom }

enum SortBy { revenueDesc, nameAsc, createdDesc }

enum _ChipKind { good, warn, bad }

class StatusCard extends StatelessWidget {
  final String tenantId;
  const StatusCard({required this.tenantId});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('tenantIndex')
          .doc(tenantId)
          .snapshots(),
      builder: (context, snap) {
        if (snap.hasError) {
          return myCard(title: '登録状況', child: Text('読込エラー: ${snap.error}'));
        }
        if (!snap.hasData) {
          return const myCard(
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
            _ => '初期費用: 未払い',
          },
          kind: switch (initStatus) {
            'paid' => _ChipKind.good,
            'checkout_open' => _ChipKind.warn,
            _ => _ChipKind.bad,
          },
        );

        // サブスク
        final subPlan = (m['subscription']?['plan'] ?? "選択なし").toString();
        final subStatus = (m['subscription']?['status'] ?? '').toString();
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
              'サブスク: $subPlan ${subStatus.toUpperCase()}${nextAt != null ? '（次回: ${_ymd(nextAt)}）' : ''}${overdue ? '（未払い）' : ''}',
          kind: overdue
              ? _ChipKind.bad
              : (subStatus == 'active' || subStatus == 'trialing')
              ? _ChipKind.good
              : _ChipKind.bad,
        );

        // Connect
        final chargesEnabled = m['connect']?['charges_enabled'] == true;
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
                label: 'コネクトアカウント: ${chargesEnabled ? '登録済み' : '未登録'}',
                kind: chargesEnabled ? _ChipKind.good : _ChipKind.bad,
              ),

              if (currentlyDue > 0)
                _statusChip(
                  label: '要提出: $currentlyDue 件',
                  kind: _ChipKind.warn,
                ),
            ],
          ),
        ];

        return myCard(
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

class myCard extends StatelessWidget {
  final String title;
  final Widget child;
  final Widget? action;
  const myCard({required this.title, required this.child, this.action});

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

class Filters extends StatelessWidget {
  final TextEditingController searchCtrl;
  final DatePreset preset;
  final void Function(DatePreset) onPresetChanged;
  final DateTime? rangeStart;
  final DateTime? rangeEndEx;
  final bool activeOnly;
  final bool chargesEnabledOnly;
  final ValueChanged<bool> onToggleActive;
  final ValueChanged<bool> onToggleCharges;
  final SortBy sortBy;
  final ValueChanged<SortBy> onSortChanged;

  const Filters({
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
          DropdownButton<DatePreset>(
            value: preset,
            onChanged: (v) => v != null ? onPresetChanged(v) : null,
            items: const [
              DropdownMenuItem(value: DatePreset.today, child: Text('今日')),
              DropdownMenuItem(value: DatePreset.yesterday, child: Text('昨日')),
              DropdownMenuItem(value: DatePreset.thisMonth, child: Text('今月')),
              DropdownMenuItem(value: DatePreset.lastMonth, child: Text('先月')),
              DropdownMenuItem(value: DatePreset.custom, child: Text('期間指定')),
            ],
          ),
          Text(rangeLabel, style: const TextStyle(color: Colors.black54)),

          // ステータスフィルタ
          FilterChip(
            label: const Text(
              '初期登録済',
              style: TextStyle(height: 1.2, fontWeight: FontWeight.w700),
            ),

            selected: activeOnly,
            onSelected: onToggleActive,
          ),

          // 並び替え
          const SizedBox(width: 8),
          DropdownButton<SortBy>(
            value: sortBy,
            onChanged: (v) => v != null ? onSortChanged(v) : null,
            items: const [
              DropdownMenuItem(
                value: SortBy.revenueDesc,
                child: Text('売上の高い順（表示内／簡易）'),
              ),
              DropdownMenuItem(value: SortBy.nameAsc, child: Text('店舗名（昇順）')),
              DropdownMenuItem(
                value: SortBy.createdDesc,
                child: Text('作成日時（新しい順）'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class Revenue {
  final int sum;
  final int count;
  const Revenue({required this.sum, required this.count});
}

class AgenciesView extends StatelessWidget {
  final String query;
  final AgenciesTab tab;
  final ValueChanged<AgenciesTab> onTabChanged;

  const AgenciesView({
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
        Expanded(child: AgentsList(query: query)),
      ],
    );
  }
}
