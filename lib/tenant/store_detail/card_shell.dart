import 'package:flutter/material.dart';

/// 白カード＋影（ネイティブ感のある入れ物）
class CardShell extends StatelessWidget {
  final Widget child;
  const CardShell({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1A000000), // 黒10%くらい
            blurRadius: 16,
            spreadRadius: 0,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: child,
    );
  }
}

class PlanPicker extends StatelessWidget {
  final String selected; // 'A' | 'B' | 'C'
  final ValueChanged<String> onChanged;
  const PlanPicker({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final plans = <PlanDef>[
      PlanDef(
        code: 'A',
        title: 'Aプラン',
        monthly: 0,
        feePct: 20,
        features: const ['月額無料', '手数料20%'],
      ),
      PlanDef(
        code: 'B',
        title: 'Bプラン',
        monthly: 1980,
        feePct: 15,
        features: const ['月額1,980円', '手数料15%'],
      ),
      PlanDef(
        code: 'C',
        title: 'Cプラン',
        monthly: 9800,
        feePct: 10,
        features: const ['月額9,800円', '手数料10%', '公式LINEリンク', 'Googleレビューリンク'],
      ),
    ];

    return LayoutBuilder(
      builder: (context, c) {
        final isWide = c.maxWidth >= 900;
        final children = plans
            .map(
              (p) => _PlanTile(
                plan: p,
                selected: selected == p.code,
                onTap: () => onChanged(p.code),
              ),
            )
            .toList();

        if (isWide) {
          return Row(
            children: [
              Expanded(child: children[0]),
              const SizedBox(width: 12),
              Expanded(child: children[1]),
              const SizedBox(width: 12),
              Expanded(child: children[2]),
            ],
          );
        } else {
          return Column(
            children: [
              children[0],
              const SizedBox(height: 12),
              children[1],
              const SizedBox(height: 12),
              children[2],
            ],
          );
        }
      },
    );
  }
}

class PlanChip extends StatelessWidget {
  final String label;
  final bool dark;
  const PlanChip({required this.label, this.dark = false});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: dark ? Colors.black : Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.black12),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: dark ? Colors.white : Colors.black87,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class PlanDef {
  final String code;
  final String title;
  final int monthly;
  final int feePct;
  final List<String> features;
  PlanDef({
    required this.code,
    required this.title,
    required this.monthly,
    required this.feePct,
    required this.features,
  });
}

class _PlanTile extends StatelessWidget {
  final PlanDef plan;
  final bool selected;
  final VoidCallback onTap;
  const _PlanTile({
    required this.plan,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? Colors.black : Colors.white,
      borderRadius: BorderRadius.circular(16),
      elevation: selected ? 8 : 4,
      shadowColor: const Color(0x1A000000),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: selected ? Colors.white : Colors.black,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      plan.code,
                      style: TextStyle(
                        color: selected ? Colors.black : Colors.white,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    plan.title,
                    style: TextStyle(
                      color: selected ? Colors.white : Colors.black87,
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    plan.monthly == 0 ? '無料' : '¥${plan.monthly}',
                    style: TextStyle(
                      color: selected ? Colors.white : Colors.black87,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                '手数料 ${plan.feePct}%',
                style: TextStyle(
                  color: selected ? Colors.white70 : Colors.black54,
                ),
              ),
              const SizedBox(height: 6),
              ...plan.features.map(
                (f) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Icon(
                        Icons.check,
                        size: 16,
                        color: selected ? Colors.white : Colors.black87,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          f,
                          style: TextStyle(
                            color: selected ? Colors.white : Colors.black87,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class AdminEntry {
  final String uid;
  final String email;
  final String name;
  final String role; // 'admin' など
  AdminEntry({
    required this.uid,
    required this.email,
    required this.name,
    required this.role,
  });
}

class AdminList extends StatelessWidget {
  final List<AdminEntry> entries;
  final ValueChanged<String> onRemove;
  const AdminList({required this.entries, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return const ListTile(title: Text('管理者がいません'));
    }
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: entries.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final e = entries[i];
        final subtitle = [
          if (e.name.isNotEmpty) e.name,
          if (e.email.isNotEmpty) e.email,
          '役割: ${e.role}',
        ].join(' / ');
        return ListTile(
          leading: const CircleAvatar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            child: Icon(Icons.admin_panel_settings),
          ),
          title: Text(
            e.uid,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: Colors.black87),
          ),
          subtitle: Text(
            subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: Colors.black87),
          ),
          trailing: IconButton(
            icon: const Icon(Icons.remove_circle_outline),
            onPressed: () => onRemove(e.uid),
            tooltip: '削除',
          ),
        );
      },
    );
  }
}
