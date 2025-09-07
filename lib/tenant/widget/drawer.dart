import 'package:flutter/material.dart';

class TenantOption {
  final String id;
  final String name;
  const TenantOption({required this.id, required this.name});
}

class AppDrawer extends StatelessWidget {
  final String? tenantName;
  final String? currentTenantId; // ★ 追加：選択表示に使用
  final int currentIndex;
  final void Function(int) onTapIndex;
  final List<TenantOption> tenantOptions;
  final void Function(String tenantId)? onChangeTenant;
  final VoidCallback? onCreateTenant;

  const AppDrawer({
    super.key,
    required this.tenantName,
    required this.currentTenantId, // ★ 追加
    required this.currentIndex,
    required this.onTapIndex,
    required this.tenantOptions,
    this.onChangeTenant,
    this.onCreateTenant,
  });

  @override
  Widget build(BuildContext context) {
    final nav = Navigator.of(context);

    final items = const [
      _NavData(0, Icons.home, 'ホーム'),
      _NavData(1, Icons.qr_code_2, '印刷'),
      _NavData(2, Icons.group, 'スタッフ'),
      _NavData(3, Icons.settings, '設定'),
    ];

    return Drawer(
      backgroundColor: Colors.white,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 8),

            // ヘッダ（現在の店舗名＋新規作成）
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 18,
                      backgroundColor: Colors.white,
                      child: Text(
                        ((tenantName ?? '？').trim().isEmpty
                                ? '？'
                                : tenantName!.characters.first)
                            .toUpperCase(),
                        style: const TextStyle(
                          color: Colors.black,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        (tenantName?.trim().isNotEmpty ?? false)
                            ? tenantName!.trim()
                            : '店舗未選択',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: () {
                        nav.pop(); // 先に Drawer を閉じる
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          onCreateTenant?.call();
                        });
                      },
                      icon: const Icon(Icons.add, color: Colors.white),
                      label: const Text(
                        '新規作成',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.white, width: 1.2),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 12),

            // ★ 店舗切替（ラジオリスト：タップで即切替）
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                '店舗を選択',
                style: TextStyle(
                  color: Colors.black.withOpacity(.6),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                children: [
                  if (tenantOptions.isEmpty)
                    const ListTile(
                      title: Text(
                        '店舗がありません',
                        style: TextStyle(color: Colors.black54),
                      ),
                      subtitle: Text(
                        '「新規作成」から追加してください',
                        style: TextStyle(color: Colors.black45),
                      ),
                    )
                  else
                    ...tenantOptions.map((o) {
                      return RadioListTile<String>(
                        value: o.id,
                        groupValue: currentTenantId,
                        dense: true,
                        activeColor: Colors.black,
                        title: Text(
                          o.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.black,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        onChanged: (v) {
                          if (v == null || v == currentTenantId) {
                            nav.pop(); // ただ閉じるだけ
                            return;
                          }
                          nav.pop(); // Drawer を閉じる
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            onChangeTenant?.call(v); // 次フレームで切替
                          });
                        },
                      );
                    }),

                  const Divider(height: 24),

                  // ナビゲーション
                  ...items.map((d) {
                    final selected = currentIndex == d.index;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: _NavTile(
                        icon: d.icon,
                        label: d.label,
                        selected: selected,
                        onTap: () {
                          nav.pop();
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            onTapIndex(d.index);
                          });
                        },
                      ),
                    );
                  }),
                ],
              ),
            ),

            const _DrawerFooter(),
          ],
        ),
      ),
    );
  }
}

class _NavTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _NavTile({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bg = selected ? Colors.black : Colors.white;
    final fg = selected ? Colors.white : Colors.black;
    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(14),
          border: selected
              ? null
              : Border.all(color: Colors.black.withOpacity(.08), width: 1),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Icon(icon, color: fg),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(color: fg, fontWeight: FontWeight.w700),
                  ),
                ),
                Icon(Icons.chevron_right, color: fg),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DrawerFooter extends StatelessWidget {
  const _DrawerFooter();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.black.withOpacity(.08), width: 1),
        ),
        child: const Row(
          children: [
            Icon(Icons.info_outline, size: 18, color: Colors.black),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                '必要なページが見つからない場合は設定から追加してください。',
                style: TextStyle(color: Colors.black, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavData {
  final int index;
  final IconData icon;
  final String label;
  const _NavData(this.index, this.icon, this.label);
}
