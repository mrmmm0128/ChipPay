import 'package:flutter/material.dart';

/// 横スクロール固定の画像ビューア
class ImagesScroller extends StatefulWidget {
  const ImagesScroller({required this.assets, this.borderRadius = 12});

  final List<String> assets;
  final double borderRadius;

  @override
  State<ImagesScroller> createState() => _ImagesScrollerState();
}

class _ImagesScrollerState extends State<ImagesScroller> {
  final _pageCtrl = PageController();
  int _page = 0;

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  void _goPrev() {
    if (_page > 0) {
      _pageCtrl.previousPage(
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut,
      );
    }
  }

  void _goNext() {
    if (_page < (widget.assets.length - 1)) {
      _pageCtrl.nextPage(
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final canPrev = _page > 0;
    final canNext = _page < (widget.assets.length - 1);

    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: Container(
        color: Colors.white,
        child: Column(
          children: [
            // ヘッダ（薄い区切り）
            const SizedBox(height: 6),
            _SwipeHint(isHorizontal: true),
            const Divider(height: 1),

            // ビュー領域（横スクロール）
            Expanded(
              child: Stack(
                children: [
                  PageView.builder(
                    controller: _pageCtrl,
                    physics: const BouncingScrollPhysics(),
                    onPageChanged: (i) => setState(() => _page = i),
                    itemCount: widget.assets.length,
                    itemBuilder: (context, index) {
                      return Center(
                        child: _ImageBox(assetPath: widget.assets[index]),
                      );
                    },
                  ),

                  // 左右チートシート（半透明の矢印）
                  if (canPrev)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: _ChevronButton(
                        icon: Icons.chevron_left,
                        onTap: _goPrev,
                        alignmentPadding: const EdgeInsets.only(left: 4),
                      ),
                    ),
                  if (canNext)
                    Align(
                      alignment: Alignment.centerRight,
                      child: _ChevronButton(
                        icon: Icons.chevron_right,
                        onTap: _goNext,
                        alignmentPadding: const EdgeInsets.only(right: 4),
                      ),
                    ),
                ],
              ),
            ),

            // ページインジケータ
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: _Dots(length: widget.assets.length, index: _page),
            ),
          ],
        ),
      ),
    );
  }
}

/// 余白に合わせて画像を綺麗に収める箱
class _ImageBox extends StatelessWidget {
  const _ImageBox({required this.assetPath});

  final String assetPath;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, c) {
        // 画像を箱にフィット（上下左右に余白が出ても崩れない）
        return ConstrainedBox(
          constraints: BoxConstraints(maxWidth: c.maxWidth),
          child: AspectRatio(
            // A4縦を想定。必要なら実画像の比を取得して動的にしてもOK。
            aspectRatio: 1 / 1.4142,
            child: FittedBox(
              fit: BoxFit.contain,
              child: Image.asset(
                assetPath,
                filterQuality: FilterQuality.medium,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 左右の矢印オーバーレイ
class _ChevronButton extends StatelessWidget {
  const _ChevronButton({
    required this.icon,
    required this.onTap,
    this.alignmentPadding,
  });

  final IconData icon;
  final VoidCallback onTap;
  final EdgeInsets? alignmentPadding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: alignmentPadding ?? EdgeInsets.zero,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.08),
            shape: BoxShape.circle,
          ),
          padding: const EdgeInsets.all(6),
          child: Icon(icon, size: 28, color: Colors.black87),
        ),
      ),
    );
  }
}

/// ドットインジケータ（軽量実装）
class _Dots extends StatelessWidget {
  const _Dots({required this.length, required this.index});

  final int length;
  final int index;

  @override
  Widget build(BuildContext context) {
    if (length <= 1) return const SizedBox.shrink();
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(length, (i) {
        final active = i == index;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          margin: const EdgeInsets.symmetric(horizontal: 3),
          width: active ? 18 : 8,
          height: 8,
          decoration: BoxDecoration(
            color: active ? Colors.black87 : Colors.black26,
            borderRadius: BorderRadius.circular(99),
          ),
        );
      }),
    );
  }
}

/// 「横にスワイプ」のヒント
class _SwipeHint extends StatelessWidget {
  const _SwipeHint({required this.isHorizontal});
  final bool isHorizontal;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.swipe, size: 18, color: Colors.black54),
          const SizedBox(width: 6),
          Text(
            isHorizontal ? '横にスワイプして表示を切り替え' : 'スワイプでスクロール',
            style: const TextStyle(color: Colors.black54, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
