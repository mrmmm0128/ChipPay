import 'package:flutter/material.dart';

/// スタッフ1件分
class StaffEntry {
  final int index;
  final String name;
  final String email;
  final String photoUrl;
  final String comment; // ← 追加
  final VoidCallback? onTap;

  StaffEntry({
    required this.index,
    required this.name,
    required this.email,
    required this.photoUrl,
    this.comment = '', // ← 空文字なら非表示
    this.onTap,
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
            childAspectRatio: 0.82, // 必要なら 0.78〜0.8 に下げて余白を増やしてください
          ),
          itemCount: entries.length,
          itemBuilder: (_, i) => StaffCircleTile(entry: entries[i]),
        );
      },
    );
  }
}

/// 丸写真 + 左上順位バッジ + 下に名前/メール/コメント（タップで詳細へ）
class StaffCircleTile extends StatelessWidget {
  final StaffEntry entry;
  const StaffCircleTile({super.key, required this.entry});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: entry.onTap != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      child: Semantics(
        button: entry.onTap != null,
        label: '${entry.name.isNotEmpty ? entry.name : "スタッフ"} の詳細',
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            onTap: entry.onTap,
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Column(
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
                                child: _RoundPhoto(
                                  url: entry.photoUrl,
                                  name: entry.name,
                                ),
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
                  // 名前
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
                  // メール（任意）
                  if (entry.email.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      entry.email,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.black54,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                  // コメント（任意）
                  if (entry.comment.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Tooltip(
                      message: entry.comment, // ホバー/長押しで全文
                      waitDuration: const Duration(milliseconds: 300),
                      child: Text(
                        entry.comment,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.black54,
                          fontSize: 12.5,
                          height: 1.25,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
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
