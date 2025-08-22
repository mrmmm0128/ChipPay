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
    final isWide = MediaQuery.of(context).size.width >= 720;
    final cross = isWide ? 5 : 3;

    return GridView.builder(
      shrinkWrap: shrinkWrap, // ← 反映
      physics: physics, // ← 反映
      padding: const EdgeInsets.all(4),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: cross,
        mainAxisSpacing: 15,
        crossAxisSpacing: 15,
        childAspectRatio: 0.9,
      ),
      itemCount: entries.length,
      itemBuilder: (_, i) {
        final e = entries[i];
        return Padding(
          // ほんの少しだけ上下左右に余白を入れて窮屈さを回避
          padding: const EdgeInsets.fromLTRB(8, 10, 8, 6),
          child: EmployeeRankTile(tenantId: tenantId, entry: e),
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
      mainAxisSize: MainAxisSize.min, // 高さに合わせて縮む
      children: [
        LayoutBuilder(
          builder: (context, c) {
            // セルの幅に対してスケール：小さい端末でも溢れない
            final double size = (c.maxWidth * 0.82).clamp(96.0, 160.0);
            return SizedBox(
              width: size,
              height: size,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  // 丸写真
                  Positioned.fill(
                    child: ClipOval(
                      child: _EmployeePhoto(
                        tenantId: tenantId,
                        employeeId: entry.employeeId,
                      ),
                    ),
                  ),
                  // 左上の順位バッジ
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
                            color: Color(0x33000000),
                            blurRadius: 6,
                            offset: Offset(0, 2),
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
        const SizedBox(height: 8), // ← 少しだけ詰める
        Text(
          entry.name.isNotEmpty ? entry.name : 'スタッフ',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 13.5, // ← わずかに小さく
            letterSpacing: 0.2,
            color: Colors.black54,
          ),
        ),
        // 補足があればここに（必要時のみ）
        // const SizedBox(height: 2),
        // Text('¥${entry.amount} / ${entry.count}回',
        //   style: const TextStyle(color: Colors.black54, fontSize: 12),
        // ),
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
