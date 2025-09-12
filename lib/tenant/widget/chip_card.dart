import 'package:flutter/material.dart';
import 'package:yourpay/tenant/widget/subscription_card.dart';

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

  void _showPayoutInfoSheet(BuildContext context, {required bool isStore}) {
    final title = isStore ? '店舗向けの受取額について' : 'スタッフ向けの受取額について';
    final formula = isStore
        ? '元金 － Stripe手数料（3.6%）－ アプリケーション手数料（サブスクによる）'
        : '元金 － Stripe手数料（3.6%）－ アプリケーション手数料（サブスクによる）－ 店舗が差し引く金額';

    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.help_outline, color: Colors.black87),
                SizedBox(width: 8),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              title,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: Colors.black87,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              formula,
              style: const TextStyle(color: Colors.black87, height: 1.5),
            ),
            const SizedBox(height: 8),
            const Text(
              '※ 手数料率や差し引き額はプランや設定により異なります。',
              style: TextStyle(color: Colors.black54, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _MetricCardMini(
            icon: Icons.store,
            label: '店舗向け',
            value: '¥$storeYen',
            sub: '$storeCount 件',
            onCardTap: onTapStore, // 本体
            onHelpTap: () =>
                _showPayoutInfoSheet(context, isStore: true), // はてな
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _MetricCardMini(
            icon: Icons.person,
            label: 'スタッフ向け',
            value: '¥$staffYen',
            sub: '$staffCount 件',
            onCardTap: onTapStaff,
            onHelpTap: () => _showPayoutInfoSheet(context, isStore: false),
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
  final VoidCallback? onCardTap; // 本体
  final VoidCallback? onHelpTap; // はてな

  const _MetricCardMini({
    required this.icon,
    required this.label,
    required this.value,
    required this.sub,
    this.onCardTap,
    this.onHelpTap,
  });

  @override
  Widget build(BuildContext context) {
    return CardShell(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 本体（ここだけ InkWell）
            Expanded(
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: onCardTap,
                  borderRadius: BorderRadius.circular(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          CircleAvatar(
                            backgroundColor: Colors.black,
                            foregroundColor: Colors.white,
                            radius: 16,
                            child: Icon(icon, size: 18),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              label,
                              style: const TextStyle(
                                color: Colors.black87,
                                fontWeight: FontWeight.w600,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
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
              ),
            ),
            if (onHelpTap != null)
              IconButton(
                onPressed: onHelpTap, // ← 完全に独立したボタン
                icon: const Icon(
                  Icons.help_outline,
                  size: 20,
                  color: Colors.black54,
                ),
                tooltip: '説明',
                padding: const EdgeInsets.only(left: 8, top: 2),
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
          ],
        ),
      ),
    );
  }
}

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
