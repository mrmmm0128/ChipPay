import 'package:flutter/material.dart';
import 'package:yourpay/endUser/store_tip_page.dart';

class TipCompletePage extends StatelessWidget {
  final String tenantId;
  final String? tenantName;
  final int? amount;
  final String? employeeName;

  const TipCompletePage({
    super.key,
    required this.tenantId,
    this.tenantName,
    this.amount,
    this.employeeName,
  });

  @override
  Widget build(BuildContext context) {
    final storeLabel = tenantName ?? 'お店';
    return Scaffold(
      appBar: AppBar(
        title: const Text('チップ'),
        automaticallyImplyLeading: false,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.check_circle, size: 80),
              const SizedBox(height: 12),
              Text(
                'チップを送信しました。',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              if (employeeName != null || amount != null) ...[
                const SizedBox(height: 8),
                Text(
                  [
                    if (employeeName != null) '宛先: $employeeName',
                    if (amount != null) '金額: ¥$amount',
                  ].join(' / '),
                ),
              ],
              const SizedBox(height: 24),
              // ① お店にチップを送る
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  icon: const Icon(Icons.store),
                  label: Text('$storeLabel にチップを送る'),
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => StoreTipPage(
                          tenantId: tenantId,
                          tenantName: storeLabel,
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
              // ② 他のスタッフにチップを送る → PublicStorePage（元画面）に戻るだけでOK
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.people_alt),
                  label: const Text('他のスタッフにチップを送る'),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
