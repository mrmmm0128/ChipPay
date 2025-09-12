import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';

/// Cプラン特典セクション（c_perks だけ）
/// - Firestore: doc['c_perks'] から thanksPhotoUrl / thanksVideoUrl を参照
/// - ローカル差し替えがあればそれを優先（_thanksPhotoPreviewBytes / _thanksPhotoUrl / _thanksVideoUrl）
/// - プレビュー枠は各1つ（写真/動画）でデザイン崩れ防止
Widget buildCPerksSection({
  required DocumentReference<Map<String, dynamic>> tenantRef,
  required TextEditingController lineUrlCtrl,
  required TextEditingController reviewUrlCtrl,
  required bool uploadingPhoto,
  required bool uploadingVideo,
  required bool savingExtras,
  required Uint8List? thanksPhotoPreviewBytes,
  required String? thanksPhotoUrlLocal,
  required String? thanksVideoUrlLocal,
  required VoidCallback onSaveExtras, // () => _saveExtras(tenantRef)
  required VoidCallback onPickPhoto, // () => _pickAndUploadPhoto(tenantRef)
  required VoidCallback onDeletePhoto, // () => _deleteThanksPhoto(tenantRef)
  required DocumentReference thanksRef,

  required void Function(BuildContext, String)
  onPreviewVideo, // showVideoPreview
  required ButtonStyle primaryBtnStyle,
}) {
  return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
    stream: tenantRef.snapshots(),
    builder: (context, snap) {
      final data = snap.data?.data() ?? const <String, dynamic>{};

      // ★ c_perks マップからサーバー値を取得
      final perks = (data['c_perks'] as Map<String, dynamic>?) ?? const {};
      final serverPhotoUrl = (perks['thanksPhotoUrl'] as String?)?.trim();
      final serverVideoUrl = (perks['thanksVideoUrl'] as String?)?.trim();
      final serverLineUrl = (perks['lineUrl'] as String?)?.trim();
      final serverReview = (perks['reviewUrl'] as String?)?.trim();

      // 初期流し込み（ユーザー入力を上書きしないよう、空のときだけ）
      if ((lineUrlCtrl.text).isEmpty && (serverLineUrl?.isNotEmpty ?? false)) {
        lineUrlCtrl.text = serverLineUrl!;
      }
      if ((reviewUrlCtrl.text).isEmpty && (serverReview?.isNotEmpty ?? false)) {
        reviewUrlCtrl.text = serverReview!;
      }

      // 表示用の最終 URL（ローカル優先）
      final displayPhotoBytes = thanksPhotoPreviewBytes;
      final displayPhotoUrl = displayPhotoBytes != null
          ? null
          : ((thanksPhotoUrlLocal?.isNotEmpty ?? false)
                ? thanksPhotoUrlLocal
                : (serverPhotoUrl?.isNotEmpty ?? false)
                ? serverPhotoUrl
                : null);

      final displayVideoUrl = (thanksVideoUrlLocal?.isNotEmpty ?? false)
          ? thanksVideoUrlLocal
          : (serverVideoUrl?.isNotEmpty ?? false)
          ? serverVideoUrl
          : null;

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(height: 1),
          const SizedBox(height: 16),
          const Text(
            'Cプランの特典（表示用リンク）',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),

          // 表示用リンク
          // ▼ ここを置き換え：LINE リンク（入力 + 個別保存ボタン）
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: lineUrlCtrl,
                  decoration: const InputDecoration(
                    labelText: '公式LINEリンク（任意）',
                    hintText: 'https://lin.ee/xxxxx',
                  ),
                  keyboardType: TextInputType.url,
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: () async {
                  final v = lineUrlCtrl.text.trim();
                  try {
                    if (v.isEmpty) {
                      // 空なら削除（フィールドを消す）
                      try {
                        await tenantRef.update({
                          'c_perks.lineUrl': FieldValue.delete(),
                        });
                      } catch (_) {
                        // doc 未作成などで失敗したら無視（実害なし）
                      }
                    } else {
                      // 値ありならマージ保存
                      await tenantRef.set({
                        'c_perks.lineUrl': v,
                      }, SetOptions(merge: true));

                      await thanksRef.set({
                        'c_perks.lineUrl': v,
                      }, SetOptions(merge: true));
                    }
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('LINEリンクを保存しました')),
                      );
                    }
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(SnackBar(content: Text('保存に失敗しました: $e')));
                    }
                  }
                },
                icon: const Icon(Icons.save),
                label: const Text('保存'),
              ),
            ],
          ),

          const SizedBox(height: 8),

          // ▼ ここを置き換え：Google レビュー（入力 + 個別保存ボタン）
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: reviewUrlCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Googleレビューリンク（任意）',
                    hintText: 'https://g.page/r/xxxxx/review',
                  ),
                  keyboardType: TextInputType.url,
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: () async {
                  final v = reviewUrlCtrl.text.trim();
                  try {
                    if (v.isEmpty) {
                      // 空なら削除
                      try {
                        await tenantRef.update({
                          'c_perks.reviewUrl': FieldValue.delete(),
                        });
                      } catch (_) {}
                    } else {
                      // 値ありならマージ保存
                      await tenantRef.set({
                        'c_perks.reviewUrl': v,
                      }, SetOptions(merge: true));

                      await thanksRef.set({
                        'c_perks.reviewUrl': v,
                      }, SetOptions(merge: true));
                    }
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Googleレビューリンクを保存しました')),
                      );
                    }
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(SnackBar(content: Text('保存に失敗しました: $e')));
                    }
                  }
                },
                icon: const Icon(Icons.save),
                label: const Text('保存'),
              ),
            ],
          ),

          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 16),
          const Text(
            'Cプランの特典（感謝の写真・動画）',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),

          // ===== 写真 =====
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 左：固定プレビュー枠（1つだけ）
              GestureDetector(
                onTap: () {
                  final hasLocal = displayPhotoBytes != null;
                  final hasRemote = (displayPhotoUrl ?? '').isNotEmpty;
                  if (!hasLocal && !hasRemote) return;
                  showDialog<void>(
                    context: context,
                    builder: (_) => Dialog(
                      insetPadding: const EdgeInsets.all(16),
                      backgroundColor: Colors.black,
                      child: InteractiveViewer(
                        child: hasLocal
                            ? Image.memory(displayPhotoBytes!)
                            : Image.network(
                                displayPhotoUrl!,
                                errorBuilder: (_, __, ___) => const Center(
                                  child: Icon(
                                    Icons.broken_image,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                      ),
                    ),
                  );
                },
                child: Container(
                  width: 96,
                  height: 96,
                  alignment: Alignment.center,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0x11000000)),
                  ),
                  child: uploadingPhoto
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : (() {
                          if (displayPhotoBytes != null) {
                            return Image.memory(
                              displayPhotoBytes!,
                              fit: BoxFit.cover,
                            );
                          }
                          if ((displayPhotoUrl ?? '').isNotEmpty) {
                            return Image.network(
                              displayPhotoUrl!,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => const Icon(
                                Icons.broken_image,
                                color: Colors.black38,
                              ),
                            );
                          }
                          return const Icon(
                            Icons.photo,
                            size: 32,
                            color: Colors.black38,
                          );
                        })(),
                ),
              ),
              const SizedBox(width: 12),

              // 右：説明＆操作
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('感謝の写真（JPG/PNG・5MBまで）'),
                    const SizedBox(height: 8),
                    if (displayPhotoBytes != null)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 6),
                        child: _HintRow('ローカルで差し替え済み（保存で反映されます）'),
                      ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          onPressed: uploadingPhoto ? null : onPickPhoto,
                          icon: const Icon(Icons.file_upload),
                          label: Text(
                            (displayPhotoBytes != null ||
                                    (displayPhotoUrl ?? '').isNotEmpty)
                                ? '写真を差し替え'
                                : '写真を選ぶ',
                          ),
                        ),
                        if ((displayPhotoUrl ?? '').isNotEmpty)
                          OutlinedButton.icon(
                            onPressed: uploadingPhoto ? null : onDeletePhoto,
                            icon: const Icon(Icons.delete_outline),
                            label: const Text('写真を削除'),
                          ),
                        if ((displayPhotoUrl ?? '').isNotEmpty)
                          OutlinedButton.icon(
                            onPressed: () => launchUrlString(
                              displayPhotoUrl!,
                              mode: LaunchMode.externalApplication,
                            ),
                            icon: const Icon(Icons.open_in_new),
                            label: const Text('写真を開く'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),

          // ===== 動画 =====
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 左：固定サムネ（1つだけ）
              Container(
                width: 96,
                height: 96,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.grey.shade200,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0x11000000)),
                ),
                child: uploadingVideo
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : ((displayVideoUrl ?? '').isNotEmpty
                          ? const Icon(Icons.play_circle_fill, size: 36)
                          : const Icon(Icons.movie, size: 32)),
              ),
              const SizedBox(width: 12),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text("チップを贈ってくれた方にお礼の動画を提供しましょう。\nスタッフ詳細画面から登録してください。"),
                ],
              ),
            ],
          ),
        ],
      );
    },
  );
}

/// 小さなヒント行（アイコン+テキスト）
class _HintRow extends StatelessWidget {
  final String text;
  const _HintRow(this.text);
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.info_outline, size: 16, color: Colors.black54),
        const SizedBox(width: 6),
        Expanded(
          child: Text(text, style: const TextStyle(color: Colors.black54)),
        ),
      ],
    );
  }
}
