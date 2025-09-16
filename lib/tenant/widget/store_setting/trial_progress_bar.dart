import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class TrialProgressBar extends StatelessWidget {
  const TrialProgressBar({
    super.key,
    this.trialStart, // 例: Firestore Timestamp.toDate()
    required this.trialEnd, // 必須推奨（これが一番正確）
    this.totalDays = 90, // 総トライアル日数（不明なら90日）
    this.onTap,
  });

  /// トライアル開始日時（省略可）
  final DateTime? trialStart;

  /// トライアル終了日時（推奨）
  final DateTime trialEnd;

  /// 総トライアル日数（trialStartが無くても%表示できるよう既定値あり）
  final int totalDays;

  /// タップ時アクション（例：課金ポータルを開く）
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final end = trialEnd.toLocal();

    // 残り日数（小数切り上げでユーザー体験を優先）
    final remainingHours = end.difference(now).inHours;
    final remainingDays = (remainingHours / 24.0).ceil();

    // 進捗率の計算
    // startがあれば (now - start) / (end - start) で厳密に
    // なければ totalDays を使って (total - remaining) / total
    double progress;
    if (trialStart != null) {
      final start = trialStart!.toLocal();
      final total = end.difference(start).inSeconds.clamp(1, 1 << 30);
      final passed = now.difference(start).inSeconds.clamp(0, total);
      progress = passed / total;
    } else {
      final rem = remainingDays.clamp(0, totalDays);
      progress = (totalDays - rem) / totalDays;
    }
    progress = progress.clamp(0.0, 1.0);

    // 表示テキスト
    final ended = now.isAfter(end);
    final df = DateFormat('yyyy/MM/dd');
    final label = ended
        ? 'トライアルは終了しました（終了: ${df.format(end)}）'
        : 'トライアル残り $remainingDays 日（終了: ${df.format(end)}）';

    // オレンジ系カラー
    const barColor = Colors.orange;
    final bgColor = Colors.orange.withOpacity(0.16);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: barColor.withOpacity(0.35)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 見出し行
              Row(
                children: [
                  Icon(
                    ended
                        ? Icons.schedule_outlined
                        : Icons.local_fire_department,
                    color: barColor,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(
                        color: ended ? Colors.black54 : Colors.black87,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // プログレスバー
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: ended ? 1.0 : progress,
                  minHeight: 10,
                  color: barColor, // フォアグラウンド（オレンジ）
                  backgroundColor: Colors.white, // バック（明るめ）
                ),
              ),
              const SizedBox(height: 6),
              // 進捗の補足テキスト
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    ended ? '完了' : '進捗 ${(progress * 100).round()}%',
                    style: TextStyle(
                      color: Colors.black54,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (!ended)
                    Text(
                      '全${trialStart != null ? end.difference(trialStart!).inDays : totalDays}日',
                      style: const TextStyle(
                        color: Colors.black38,
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
