import 'package:flutter/material.dart';

/// 使い方: MaterialAppの画面として表示
///   home: const LoadingPage(message: '読み込み中...'),
class LoadingPage extends StatelessWidget {
  final String message;
  const LoadingPage({super.key, this.message = 'Loading...'});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white, // 好みで
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth;
            final imgW = (w / 4).clamp(64.0, 240.0); // ← width / 4

            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // ロゴ画像
                  Image.asset(
                    'assets/posters/ZOTMAN.png',
                    width: imgW,
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.high,
                    errorBuilder: (_, __, ___) => Icon(
                      Icons.image_not_supported_outlined,
                      size: imgW,
                      color: Colors.black26,
                    ),
                  ),
                  const SizedBox(height: 20),
                  // ローディングインジケータ
                  const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 2.6),
                  ),
                  const SizedBox(height: 12),
                  // メッセージ
                  Text(
                    message,
                    style: const TextStyle(
                      color: Colors.black87,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
