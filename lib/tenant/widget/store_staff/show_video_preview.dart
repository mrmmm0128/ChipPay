import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:video_player/video_player.dart';

void showVideoPreview(BuildContext context, String url) {
  showDialog<void>(
    context: context,
    barrierColor: Colors.black54,
    builder: (_) => _VideoPreviewDialog(url: url),
  );
}

class _VideoPreviewDialog extends StatefulWidget {
  final String url;
  const _VideoPreviewDialog({required this.url});

  @override
  State<_VideoPreviewDialog> createState() => _VideoPreviewDialogState();
}

class _VideoPreviewDialogState extends State<_VideoPreviewDialog> {
  late final VideoPlayerController _controller;
  bool _inited = false;
  String? _err;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url))
      ..setLooping(true);
    _controller
        .initialize()
        .then((_) {
          if (!mounted) return;
          setState(() => _inited = true);
          _controller.play();
        })
        .catchError((e) {
          if (!mounted) return;
          setState(() => _err = e.toString());
        });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ratio = (_inited && _controller.value.isInitialized)
        ? (_controller.value.aspectRatio == 0
              ? 16 / 9
              : _controller.value.aspectRatio)
        : 16 / 9;

    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      backgroundColor: Colors.black,
      child: AspectRatio(
        aspectRatio: ratio,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (_err != null) ...[
              const Icon(Icons.broken_image, color: Colors.white70, size: 40),
              const SizedBox(height: 8),
              Positioned(
                bottom: 12,
                child: TextButton.icon(
                  onPressed: () => launchUrlString(
                    widget.url,
                    mode: LaunchMode.externalApplication,
                    webOnlyWindowName: '_self', // Webは新しいタブで開く
                  ),
                  icon: const Icon(Icons.open_in_new, color: Colors.white),
                  label: const Text(
                    '開く',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ),
            ] else if (!_inited) ...[
              const CircularProgressIndicator(color: Colors.white),
            ] else ...[
              // 再生面
              GestureDetector(
                onTap: () {
                  setState(() {
                    _controller.value.isPlaying
                        ? _controller.pause()
                        : _controller.play();
                  });
                },
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    VideoPlayer(_controller),
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: VideoProgressIndicator(
                        _controller,
                        allowScrubbing: true,
                        padding: const EdgeInsets.only(bottom: 4),
                        colors: VideoProgressColors(
                          playedColor: Colors.white,
                          bufferedColor: Colors.white30,
                          backgroundColor: Colors.white10,
                        ),
                      ),
                    ),
                    if (!_controller.value.isPlaying)
                      const Icon(
                        Icons.play_circle_filled,
                        color: Colors.white70,
                        size: 72,
                      ),
                  ],
                ),
              ),
            ],

            // 閉じるボタン
            Positioned(
              right: 8,
              top: 8,
              child: IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close, color: Colors.white),
                tooltip: '閉じる',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
