// ======= 店舗行（売上は非同期集計） =======
import 'package:flutter/material.dart';
import 'package:yourpay/appadmin/util.dart';

class TenantTile extends StatefulWidget {
  final String tenantId;
  final String ownerUid;
  final String name;
  final String status;
  final String plan;
  final bool chargesEnabled;
  final DateTime? createdAt;
  final String rangeLabel;
  final Future<Revenue> Function() loadRevenue;
  final VoidCallback onTap;
  final String Function(int) yen;

  // ▼ 追加：サブスク表示用
  final String subPlan;
  final String subStatus;
  final bool subOverdue;
  final DateTime? subNextPaymentAt;

  // ▼ 修正：nullable にする
  final String? download;

  const TenantTile({
    super.key,
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
    required this.subPlan,
    required this.subStatus,
    required this.subOverdue,
    required this.subNextPaymentAt,
    this.download, // ← nullable
  });

  @override
  State<TenantTile> createState() => _TenantTileState();
}

class _TenantTileState extends State<TenantTile> {
  Revenue? _rev;
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
    final createdLabel = widget.createdAt != null
        ? 'Created: ${_ymd(widget.createdAt!)}'
        : null;

    final subtitleLines = <String>[
      'ID: ${widget.tenantId}',
      if (widget.plan.isNotEmpty)
        'Plan: ${widget.plan} / Status: ${widget.status}${widget.chargesEnabled ? '/ コネクトアカウント作成済' : ''}',

      if (createdLabel != null) createdLabel,
    ];

    final posterLabel = (widget.download ?? '') == 'done'
        ? 'ポスターダウンロード済'
        : 'ポスター未ダウンロード';

    return ListTile(
      onTap: widget.onTap,
      title: Text(
        widget.name.isEmpty ? '設定なし' : widget.name,
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
        ],
      ),
    );
  }
}
