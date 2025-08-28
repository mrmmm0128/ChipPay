import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

/// ランキング1件分のデータ
class RankEntry {
  final int rank;
  final String employeeId;
  final String name;
  final int amount;
  final int count;
  RankEntry({
    required this.rank,
    required this.employeeId,
    required this.name,
    required this.amount,
    required this.count,
  });
}

/// レスポンシブなグリッド（スマホ2 / タブ3 / PC4列）
class RankingGrid extends StatelessWidget {
  final String tenantId;
  final List<RankEntry> entries;
  final bool shrinkWrap; // ← 追加
  final ScrollPhysics? physics; // ← 追加

  const RankingGrid({
    super.key,
    required this.tenantId,
    required this.entries,
    this.shrinkWrap = false, // 既定は従来どおり
    this.physics,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        // 幅で列数をきめ細かく調整
        // 〜359px: 2列 / 360〜599: 3列 / 600〜899: 4列 / 900〜: 5列
        final int cross = w < 481 ? 2 : (w < 600 ? 3 : (w < 900 ? 4 : 5));
        final double spacing = w < 360 ? 10 : 15;
        final double aspect = w < 360 ? 0.88 : 0.9; // 狭い端末はわずかに背を低く

        return GridView.builder(
          shrinkWrap: shrinkWrap, // 呼び出し側で true を渡せる
          physics: physics, // 呼び出し側で NeverScrollable を渡せる
          padding: const EdgeInsets.all(4),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cross,
            mainAxisSpacing: spacing,
            crossAxisSpacing: spacing,
            childAspectRatio: aspect,
          ),
          itemCount: entries.length,
          itemBuilder: (_, i) {
            final e = entries[i];
            return Padding(
              padding: const EdgeInsets.fromLTRB(8, 10, 8, 6),
              child: EmployeeRankTile(tenantId: tenantId, entry: e),
            );
          },
        );
      },
    );
  }
}

class EmployeeRankTile extends StatelessWidget {
  final String tenantId;
  final RankEntry entry;
  const EmployeeRankTile({
    super.key,
    required this.tenantId,
    required this.entry,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        LayoutBuilder(
          builder: (context, c) {
            // セルの「短辺」に合わせるのがコツ（縦に溢れづらい）
            final double size = (c.biggest.shortestSide * 0.78)
                .clamp(90.0, 150.0)
                .toDouble();

            return SizedBox(
              width: size,
              height: size,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: ClipOval(
                      child: _EmployeePhoto(
                        tenantId: tenantId,
                        employeeId: entry.employeeId,
                      ),
                    ),
                  ),
                  Positioned(
                    top: 6,
                    left: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black,
                        borderRadius: BorderRadius.circular(6),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x22000000), // 影を弱めて視覚的なはみ出しも軽減
                            blurRadius: 4,
                            offset: Offset(0, 1),
                          ),
                        ],
                      ),
                      child: Text(
                        '${entry.rank}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 8),
        Text(
          entry.name.isNotEmpty ? entry.name : 'スタッフ',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 13.5,
            letterSpacing: 0.2,
            color: Colors.black54,
          ),
        ),
      ],
    );
  }
}

/// 社員写真（Firestoreから photoUrl を取得。無ければプレースホルダ）
class _EmployeePhoto extends StatelessWidget {
  final String tenantId;
  final String employeeId;
  const _EmployeePhoto({required this.tenantId, required this.employeeId});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('tenants')
          .doc(tenantId)
          .collection('employees')
          .doc(employeeId)
          .snapshots(),
      builder: (context, snap) {
        String? url;
        String? name;
        if (snap.hasData && snap.data!.exists) {
          final d = snap.data!.data() as Map<String, dynamic>?;
          url = d?['photoUrl'] as String?;
          name = d?['name'] as String?;
        }

        if (url != null && url.isNotEmpty) {
          return Image.network(
            url,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _placeholder(name),
            loadingBuilder: (context, child, progress) {
              if (progress == null) return child;
              return const Center(
                child: CircularProgressIndicator(strokeWidth: 2),
              );
            },
          );
        }
        return _placeholder(name);
      },
    );
  }

  Widget _placeholder(String? name) {
    // イニシャル風の簡易プレースホルダ
    final initial = (name ?? '').trim().isNotEmpty
        ? name!.characters.first.toUpperCase()
        : '?';
    return Container(
      color: Colors.black12,
      child: Center(
        child: Text(
          initial,
          style: const TextStyle(
            fontSize: 36,
            fontWeight: FontWeight.w800,
            color: Colors.black45,
          ),
        ),
      ),
    );
  }
}
