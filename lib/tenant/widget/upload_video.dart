// lib/tenant/staff/widgets/staff_thanks_video_manager.dart
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

class StaffThanksVideoManager extends StatefulWidget {
  final String tenantId;
  final String staffId;
  final String? staffName;

  const StaffThanksVideoManager({
    super.key,
    required this.tenantId,
    required this.staffId,
    this.staffName,
  });

  @override
  State<StaffThanksVideoManager> createState() =>
      _StaffThanksVideoManagerState();
}

class _StaffThanksVideoManagerState extends State<StaffThanksVideoManager> {
  CollectionReference<Map<String, dynamic>> get _videosCol => FirebaseFirestore
      .instance
      .collection('publicThanks')
      .doc(widget.tenantId)
      .collection('staff')
      .doc(widget.staffId)
      .collection('videos');

  Future<void> _pickAndUpload() async {
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['mp4', 'mov', 'm4v', 'webm'],
        allowMultiple: false,
        withData: true, // Web/デスクトップ対応
      );
      if (picked == null || picked.files.isEmpty) return;

      final f = picked.files.single;
      Uint8List? bytes = f.bytes;
      if (bytes == null && f.readStream != null) {
        final buf = <int>[];
        await for (final c in f.readStream!) {
          buf.addAll(c);
        }
        bytes = Uint8List.fromList(buf);
      }
      if (bytes == null) {
        _toast('動画の読み込みに失敗しました');
        return;
      }

      // Firestore ドキュメントを確保
      final docRef = _videosCol.doc();

      String contentType = _detectVideoContentType(f.name);
      final ext = contentType.split('/').last;

      final storagePath =
          'publicThanks/${widget.tenantId}/staff/${widget.staffId}/videos/${docRef.id}.$ext';
      final storageRef = FirebaseStorage.instance.ref(storagePath);

      // 進捗ダイアログ
      final progress = ValueNotifier<double>(0);
      _showProgressDialog(progress);

      final metadata = SettableMetadata(contentType: contentType);
      final task = storageRef.putData(bytes, metadata);
      task.snapshotEvents.listen((s) {
        if (s.totalBytes > 0) {
          progress.value = s.bytesTransferred / s.totalBytes;
        }
      });

      await task;
      final url = await storageRef.getDownloadURL();

      await docRef.set({
        'tenantId': widget.tenantId,
        'staffId': widget.staffId,
        'name': f.name,
        'url': url,
        'storagePath': storagePath,
        'contentType': contentType,
        'size': bytes.length,
        'published': true,
        // 並び順は昇順、作成時刻ミリ秒でソート可能
        'order': DateTime.now().millisecondsSinceEpoch,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        // 任意メタ
        'title': f.name,
        'description': '',
        'durationMs': null,
        'thumbUrl': null,
      });

      if (mounted) Navigator.of(context).maybePop(); // 進捗ダイアログを閉じる
      _toast('アップロードしました');
    } catch (e) {
      Navigator.of(context).maybePop();
      _toast('アップロード失敗: $e');
    }
  }

  String _detectVideoContentType(String? name) {
    final ext = (name ?? '').split('.').last.toLowerCase();
    switch (ext) {
      case 'mp4':
      case 'm4v':
        return 'video/mp4';
      case 'mov':
        return 'video/quicktime';
      case 'webm':
        return 'video/webm';
      default:
        return 'video/mp4';
    }
  }

  void _showProgressDialog(ValueNotifier<double> progress) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => ValueListenableBuilder<double>(
        valueListenable: progress,
        builder: (_, v, __) => AlertDialog(
          title: const Text('アップロード中'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: v == 0 ? null : v),
              const SizedBox(height: 8),
              Text(v == 0 ? '準備中…' : '${(v * 100).toStringAsFixed(0)}%'),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _deleteVideo(Map<String, dynamic> data, String docId) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('削除しますか？'),
        content: Text(data['name'] ?? 'この動画を削除します。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    try {
      final path = (data['storagePath'] as String?) ?? '';
      if (path.isNotEmpty) {
        await FirebaseStorage.instance.ref(path).delete();
      }
      await _videosCol.doc(docId).delete();
      _toast('削除しました');
    } catch (e) {
      _toast('削除に失敗: $e');
    }
  }

  Future<void> _togglePublish(String docId, bool value) async {
    try {
      await _videosCol.doc(docId).set({
        'published': value,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      _toast('更新に失敗: $e');
    }
  }

  Future<void> _rename(String docId, String currentTitle) async {
    final ctrl = TextEditingController(text: currentTitle);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('タイトルを編集'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'タイトル'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _videosCol.doc(docId).set({
        'title': ctrl.text.trim(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      _toast('保存に失敗: $e');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _preview(String url) async {
    await showDialog(
      context: context,
      builder: (_) => _VideoPreviewDialog(url: url),
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.staffName == null
        ? 'Thanks動画'
        : '${widget.staffName} の Thanks動画';
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                OutlinedButton.icon(
                  onPressed: _pickAndUpload,
                  icon: const Icon(Icons.file_upload),
                  label: const Text('動画をアップロード'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _videosCol
                  .orderBy('order', descending: false)
                  .snapshots(),
              builder: (context, snap) {
                if (snap.hasError) {
                  return ListTile(
                    leading: const Icon(Icons.error_outline, color: Colors.red),
                    title: const Text('読み込みに失敗しました'),
                    subtitle: Text('${snap.error}'),
                  );
                }
                if (!snap.hasData) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(12),
                      child: CircularProgressIndicator(),
                    ),
                  );
                }
                final docs = snap.data!.docs;
                if (docs.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      'まだ動画はありません。右上の「動画をアップロード」から追加してください。',
                      style: TextStyle(color: Colors.black54),
                    ),
                  );
                }

                return ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: docs.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final d = docs[i];
                    final m = d.data();
                    final title =
                        (m['title'] as String?) ??
                        (m['name'] as String? ?? '動画');
                    final published = (m['published'] as bool?) ?? false;
                    final url = (m['url'] as String?) ?? '';
                    final createdAt = (m['createdAt'] as Timestamp?);
                    final when = createdAt == null
                        ? ''
                        : _fmt(createdAt.toDate());

                    return ListTile(
                      leading: const CircleAvatar(child: Icon(Icons.movie)),
                      title: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(when),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Switch(
                            value: published,
                            onChanged: (v) => _togglePublish(d.id, v),
                          ),
                          IconButton(
                            tooltip: '再生',
                            onPressed: url.isEmpty ? null : () => _preview(url),
                            icon: const Icon(Icons.play_circle_fill),
                          ),
                          IconButton(
                            tooltip: '名前変更',
                            onPressed: () => _rename(d.id, title),
                            icon: const Icon(Icons.edit),
                          ),
                          IconButton(
                            tooltip: '削除',
                            onPressed: () => _deleteVideo(m, d.id),
                            icon: const Icon(Icons.delete_outline),
                          ),
                        ],
                      ),
                      onTap: url.isEmpty ? null : () => _preview(url),
                    );
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  String _fmt(DateTime d) =>
      '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

class _VideoPreviewDialog extends StatefulWidget {
  final String url;
  const _VideoPreviewDialog({required this.url});

  @override
  State<_VideoPreviewDialog> createState() => _VideoPreviewDialogState();
}

class _VideoPreviewDialogState extends State<_VideoPreviewDialog> {
  VideoPlayerController? _controller;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url))
      ..initialize().then((_) {
        if (mounted) setState(() {});
        _controller?.play();
      });
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      contentPadding: const EdgeInsets.all(8),
      content: AspectRatio(
        aspectRatio: _controller?.value.aspectRatio == 0
            ? 16 / 9
            : (_controller?.value.aspectRatio ?? 16 / 9),
        child: _controller != null && _controller!.value.isInitialized
            ? Stack(
                children: [
                  VideoPlayer(_controller!),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: VideoProgressIndicator(
                      _controller!,
                      allowScrubbing: true,
                    ),
                  ),
                ],
              )
            : const SizedBox(
                height: 180,
                child: Center(child: CircularProgressIndicator()),
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('閉じる'),
        ),
      ],
    );
  }
}
