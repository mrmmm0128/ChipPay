import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

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
