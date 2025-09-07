import 'package:flutter/material.dart';
import 'package:yourpay/tenant/widget/card_shell.dart';

/// 期間ピル（黒=選択中）
class RangePill extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const RangePill({
    super.key,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bg = active ? Colors.black : Colors.white;
    final fg = active ? Colors.white : Colors.black87;
    final border = active ? Colors.black : Colors.black26;

    return Material(
      color: Colors.transparent, // InkWellのリップル用
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          // ← 常に縦横センターに見えるよう最小サイズを確保
          constraints: const BoxConstraints(minHeight: 32, minWidth: 48),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center, // ← 縦横センター
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: border),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center, // ← 念のため横もセンター
            style: TextStyle(
              color: fg,
              fontWeight: FontWeight.w700,
              // 必要ならフォント指定:
              // fontFamily: 'LINEseed',
            ),
          ),
        ),
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
