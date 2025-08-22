import 'package:flutter/material.dart';

/// スタッフ1件分
class StaffEntry {
  final int index;
  final String name;
  final String email;
  final String photoUrl;
  StaffEntry({
    required this.index,
    required this.name,
    required this.email,
    required this.photoUrl,
  });
}

/// スマホ2 / タブ3 / PC4 列のグリッド
class StaffGalleryGrid extends StatelessWidget {
  final List<StaffEntry> entries;
  const StaffGalleryGrid({super.key, required this.entries});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        final cols = w >= 1100 ? 4 : (w >= 800 ? 3 : 2);
        return GridView.builder(
          padding: const EdgeInsets.symmetric(vertical: 4),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            mainAxisSpacing: 24,
            crossAxisSpacing: 24,
            childAspectRatio: 0.82,
          ),
          itemCount: entries.length,
          itemBuilder: (_, i) => StaffCircleTile(entry: entries[i]),
        );
      },
    );
  }
}

/// 丸写真 + 左上順位バッジ + 下に名前/メール
class StaffCircleTile extends StatelessWidget {
  final StaffEntry entry;
  const StaffCircleTile({super.key, required this.entry});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        LayoutBuilder(
          builder: (context, c) {
            final double size = c.maxWidth.clamp(120.0, 180.0);
            return SizedBox(
              width: size,
              height: size,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  // 丸写真
                  Positioned.fill(
                    child: ClipOval(
                      child: _RoundPhoto(url: entry.photoUrl, name: entry.name),
                    ),
                  ),
                  // 左上の順位バッジ
                  Positioned(
                    top: 8,
                    left: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
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
                        '${entry.index}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 10),
        Text(
          entry.name.isNotEmpty ? entry.name : 'スタッフ',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
            color: Colors.black87,
          ),
        ),
        if (entry.email.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            entry.email,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.black54, fontSize: 12.5),
          ),
        ],
      ],
    );
  }
}

/// 画像 or イニシャルのプレースホルダ
class _RoundPhoto extends StatelessWidget {
  final String url;
  final String name;
  const _RoundPhoto({required this.url, required this.name});

  @override
  Widget build(BuildContext context) {
    if (url.isNotEmpty) {
      return Image.network(
        url,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _ph(),
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        },
      );
    }
    return _ph();
  }

  Widget _ph() {
    final initial = name.trim().isNotEmpty
        ? name.trim().substring(0, 1).toUpperCase()
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
