import 'package:flutter/material.dart';
import 'package:yourpay/tenant/store_detail/card_shell.dart';

/// 合計金額・件数の2枚組メトリクス
class HomeMetrics extends StatelessWidget {
  final int totalYen;
  final int count;
  final VoidCallback? onTapTotal; // ← 追加

  const HomeMetrics({
    super.key,
    required this.totalYen,
    required this.count,
    this.onTapTotal, // ← 追加
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: InkWell(
            onTap: onTapTotal,
            child: _MetricCard(
              label: '総チップ金額',
              value: '¥${totalYen.toString()}',
              icon: Icons.payments,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _MetricCard(
            label: '取引回数',
            value: '$count 件',
            icon: Icons.receipt_long,
          ),
        ),
      ],
    );
  }
}

class _MetricCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  const _MetricCard({
    required this.label,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return CardShell(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
              child: Icon(icon),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: const TextStyle(color: Colors.black54)),
                  const SizedBox(height: 4),
                  Text(
                    value,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: Colors.black87,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// スタッフ集計用の軽いモデル
class StaffAgg {
  StaffAgg({required this.name});
  final String name;
  int total = 0;
  int count = 0;
}

class TotalsCard extends StatelessWidget {
  final int totalYen;
  final int count;
  final VoidCallback? onTap;

  const TotalsCard({
    super.key,
    required this.totalYen,
    required this.count,
    this.onTap,
  });

  String _yen(int v) => '¥${v.toString()}';

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: CardShell(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              // 左：総チップ金額
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '総チップ金額',
                      style: TextStyle(fontSize: 12, color: Colors.black54),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _yen(totalYen),
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: Colors.black,
                      ),
                    ),
                  ],
                ),
              ),
              // 仕切り線
              Container(
                width: 1,
                height: 36,
                color: Colors.black12,
                margin: const EdgeInsets.symmetric(horizontal: 12),
              ),
              // 右：取引回数
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    const Text(
                      '取引回数',
                      style: TextStyle(fontSize: 12, color: Colors.black54),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$count 件',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: Colors.black,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
