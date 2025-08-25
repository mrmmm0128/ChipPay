import 'package:flutter/material.dart';
import 'package:yourpay/tenant/store_detail/card_shell.dart';

/// 期間ピル（黒=選択中）
class RangePill extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback? onTap;
  final IconData? icon;
  const RangePill({
    required this.label,
    required this.active,
    this.onTap,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final child = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 16, color: active ? Colors.white : Colors.black87),
          const SizedBox(width: 6),
        ],
        Text(
          label,
          style: TextStyle(
            color: active ? Colors.white : Colors.black87,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );

    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: active ? Colors.black : Colors.white,
          borderRadius: BorderRadius.circular(999),
          boxShadow: const [
            BoxShadow(
              color: Color(0x14000000),
              blurRadius: 10,
              offset: Offset(0, 4),
            ),
          ],
          border: Border.all(color: active ? Colors.black : Colors.black12),
        ),
        child: child,
      ),
    );
  }
}

/// 店舗向け・スタッフ向けの内訳（2枚）
class SplitMetricsRow extends StatelessWidget {
  final int storeYen;
  final int storeCount;
  final int staffYen;
  final int staffCount;

  // ★ 追加：タップ時のコールバック
  final VoidCallback? onTapStore;
  final VoidCallback? onTapStaff;

  const SplitMetricsRow({
    super.key,
    required this.storeYen,
    required this.storeCount,
    required this.staffYen,
    required this.staffCount,
    this.onTapStore,
    this.onTapStaff,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          // ★ 追加：タップラップ
          child: GestureDetector(
            onTap: onTapStore,
            behavior: HitTestBehavior.opaque,
            child: _MetricCardMini(
              icon: Icons.store,
              label: '店舗向け',
              value: '¥$storeYen',
              sub: '$storeCount 件',
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          // ★ 追加：タップラップ
          child: GestureDetector(
            onTap: onTapStaff,
            behavior: HitTestBehavior.opaque,
            child: _MetricCardMini(
              icon: Icons.person,
              label: 'スタッフ向け',
              value: '¥$staffYen',
              sub: '$staffCount 件',
            ),
          ),
        ),
      ],
    );
  }
}

class _MetricCardMini extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final String sub;
  const _MetricCardMini({
    required this.icon,
    required this.label,
    required this.value,
    required this.sub,
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
                  const SizedBox(height: 2),
                  Text(sub, style: const TextStyle(color: Colors.black54)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
