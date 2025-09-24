import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

/// Bプラン特典（公式LINEリンクのみ）
/// - 読み込み: b_perks.lineUrl → c_perks.lineUrl の順で反映
/// - 保存: 互換のため b_perks.lineUrl と c_perks.lineUrl の両方に保存（片方だけで良ければ下の片方を消してください）
Widget buildBPerksSection({
  required DocumentReference<Map<String, dynamic>> tenantRef,
  required DocumentReference thanksRef, // publicThanks 側にもミラーしたい場合
  required TextEditingController lineUrlCtrl,
  required ButtonStyle primaryBtnStyle,
}) {
  return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
    stream: tenantRef.snapshots(),
    builder: (context, snap) {
      final data = snap.data?.data() ?? const <String, dynamic>{};

      final bPerks =
          (data['b_perks'] as Map?)?.cast<String, dynamic>() ?? const {};
      final cPerks =
          (data['c_perks'] as Map?)?.cast<String, dynamic>() ?? const {};

      // 既に入力済みなら上書きしない
      if (lineUrlCtrl.text.isEmpty) {
        final fromB = (bPerks['lineUrl'] as String?)?.trim();
        final fromC = (cPerks['lineUrl'] as String?)?.trim();
        final v = (fromB?.isNotEmpty ?? false)
            ? fromB
            : ((fromC?.isNotEmpty ?? false) ? fromC : null);
        if (v != null) lineUrlCtrl.text = v;
      }

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(height: 1),
          const SizedBox(height: 16),
          const Text(
            'Bプランの特典（表示用リンク）',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),

          // 公式LINEリンク（入力 + 個別保存ボタン）
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
                style: primaryBtnStyle,
                onPressed: () async {
                  final v = lineUrlCtrl.text.trim();
                  try {
                    if (v.isEmpty) {
                      // 空なら削除
                      // try {
                      //   await tenantRef.update({
                      //     'b_perks.lineUrl': FieldValue.delete(),
                      //   });
                      // } catch (_) {}
                      try {
                        // 互換のため c_perks 側も削除（不要なら消してください）
                        await tenantRef.update({
                          'c_perks.lineUrl': FieldValue.delete(),
                        });
                      } catch (_) {}

                      // 公開側も消したい場合
                      try {
                        await thanksRef.update({
                          'c_perks.lineUrl': FieldValue.delete(),
                        });
                      } catch (_) {}
                    } else {
                      // 値ありなら保存（b_perks と c_perks の両方にミラー）
                      await tenantRef.set({
                        'c_perks.lineUrl': v,
                      }, SetOptions(merge: true));

                      // 公開（publicThanks）側にも残したい場合
                      await thanksRef.set({
                        'c_perks.lineUrl': v,
                      }, SetOptions(merge: true));
                    }

                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('公式LINEリンクを保存しました')),
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

          // BはLINEのみなので、この下の写真/動画UIはなし
        ],
      );
    },
  );
}
