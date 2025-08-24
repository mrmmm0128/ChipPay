import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';

import 'public_store_page.dart';

class TipCompletePage extends StatefulWidget {
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
  State<TipCompletePage> createState() => _TipCompletePageState();
}

class _TipCompletePageState extends State<TipCompletePage> {
  Future<_LinksGateResult>? _linksGateFuture;

  @override
  void initState() {
    super.initState();
    _linksGateFuture = _loadLinksGate();
  }

  Future<_LinksGateResult> _loadLinksGate() async {
    // Firestoreからテナント情報取得 → サブスクCタイプ判定
    final doc = await FirebaseFirestore.instance
        .collection('tenants')
        .doc(widget.tenantId)
        .get();

    final data = (doc.data() ?? <String, dynamic>{});
    final isSubC = _isSubscriptionC(data);

    return _LinksGateResult(
      isSubC: isSubC,
      googleReviewUrl: (data['googleReviewUrl'] as String?) ?? '',
      lineOfficialUrl: (data['lineOfficialUrl'] as String?) ?? '',
    );
  }

  bool _isSubscriptionC(Map<String, dynamic> data) {
    final v =
        (data['subscription']?['plan'] ??
                data['subscriptionPlan'] ??
                data['plan'] ??
                data['subscription_type'] ??
                '')
            .toString()
            .toUpperCase()
            .trim();
    return v == 'C';
  }

  void _navigatePublicStorePage() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const PublicStorePage(),
        settings: RouteSettings(
          arguments: {
            'tenantId': widget.tenantId,
            'tenantName': widget.tenantName,
          },
        ),
      ),
    );
  }

  Future<void> _openStoreTipBottomSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _StoreTipBottomSheet(
        tenantId: widget.tenantId,
        tenantName: widget.tenantName,
      ),
    );
  }

  Future<void> _openUrl(String url) async {
    if (url.isEmpty) return;
    await launchUrlString(url, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final storeLabel = widget.tenantName ?? 'お店';

    return Scaffold(
      appBar: AppBar(
        title: const Text('チップ'),
        automaticallyImplyLeading: false,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.check_circle, size: 80),
                const SizedBox(height: 12),
                Text(
                  'チップを送信しました。',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                if (widget.employeeName != null || widget.amount != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    [
                      if (widget.employeeName != null)
                        '宛先: ${widget.employeeName}',
                      if (widget.amount != null) '金額: ¥${widget.amount}',
                    ].join(' / '),
                  ),
                ],
                const SizedBox(height: 24),

                // ① お店にチップを送る（ボトムシート）
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.store),
                    label: Text('$storeLabel にチップを送る'),
                    onPressed: _openStoreTipBottomSheet,
                  ),
                ),
                const SizedBox(height: 8),

                // ② 他のスタッフにチップを送る
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.people_alt),
                    label: const Text('他のスタッフにチップを送る'),
                    onPressed: _navigatePublicStorePage,
                  ),
                ),

                const SizedBox(height: 24),
                const Divider(),

                // ▼ サブスクC限定の導線（Googleレビュー / LINE公式）
                FutureBuilder<_LinksGateResult>(
                  future: _linksGateFuture,
                  builder: (context, snap) {
                    if (snap.connectionState == ConnectionState.waiting) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: SizedBox(
                          height: 24,
                          width: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      );
                    }
                    if (snap.hasError || !snap.hasData) {
                      return const SizedBox.shrink();
                    }
                    final r = snap.data!;
                    if (!r.isSubC) return const SizedBox.shrink();

                    final hasReview =
                        (r.googleReviewUrl != null &&
                        r.googleReviewUrl!.isNotEmpty);
                    final hasLine =
                        (r.lineOfficialUrl != null &&
                        r.lineOfficialUrl!.isNotEmpty);
                    if (!hasReview && !hasLine) return const SizedBox.shrink();

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(height: 16),
                        Text(
                          'ご協力のお願い',
                          style: Theme.of(context).textTheme.titleMedium,
                          textAlign: TextAlign.left,
                        ),
                        const SizedBox(height: 8),
                        if (hasReview)
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              icon: const Icon(Icons.reviews_outlined),
                              label: const Text('Google レビューを書く'),
                              onPressed: () => _openUrl(r.googleReviewUrl!),
                            ),
                          ),
                        if (hasReview && hasLine) const SizedBox(height: 8),
                        if (hasLine)
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              icon: const Icon(Icons.chat_bubble_outline),
                              label: const Text('LINE公式を友だち追加'),
                              onPressed: () => _openUrl(r.lineOfficialUrl!),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// リンク表示用の判定結果
class _LinksGateResult {
  final bool isSubC;
  final String? googleReviewUrl;
  final String? lineOfficialUrl;
  const _LinksGateResult({
    required this.isSubC,
    this.googleReviewUrl,
    this.lineOfficialUrl,
  });
}

class _StoreTipBottomSheet extends StatefulWidget {
  final String tenantId;
  final String? tenantName;

  const _StoreTipBottomSheet({required this.tenantId, this.tenantName});

  @override
  State<_StoreTipBottomSheet> createState() => _StoreTipBottomSheetState();
}

class _StoreTipBottomSheetState extends State<_StoreTipBottomSheet> {
  int _amount = 500; // デフォルト金額
  bool _loading = false;

  static const int _maxStoreTip = 1000000; // 最大金額（100万円）
  final _presets = const [100, 300, 500, 1000, 3000, 5000, 10000];

  void _setAmount(int value) {
    setState(() => _amount = value.clamp(0, _maxStoreTip));
  }

  void _appendDigit(int digit) {
    setState(() => _amount = (_amount * 10 + digit).clamp(0, _maxStoreTip));
  }

  void _appendDoubleZero() {
    if (_amount > 0) {
      setState(() => _amount = (_amount * 100).clamp(0, _maxStoreTip));
    }
  }

  void _backspace() {
    setState(() => _amount = _amount ~/ 10);
  }

  Future<void> _goToStripe() async {
    if (_amount <= 0 || _amount > _maxStoreTip) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('1〜1,000,000 円で入力してください')));
      return;
    }

    setState(() => _loading = true);
    try {
      final callable = FirebaseFunctions.instance.httpsCallable(
        'createStoreTipSessionPublic',
      );
      final response = await callable.call({
        'tenantId': widget.tenantId,
        'amount': _amount,
        'memo': 'Tip to store ${widget.tenantName ?? ''}',
      });
      final data = Map<String, dynamic>.from(response.data as Map);
      final checkoutUrl = data['checkoutUrl'] as String?;
      if (checkoutUrl != null && checkoutUrl.isNotEmpty) {
        Navigator.of(context).pop(); // ボトムシートを閉じる
        await launchUrlString(
          checkoutUrl,
          mode: LaunchMode.externalApplication,
        );
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('決済URLの取得に失敗しました')));
      }
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('エラー: $e')));
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // タイトル
          Row(
            children: [
              const Icon(Icons.storefront, color: Colors.black87),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.tenantName == null
                      ? '店舗にチップ'
                      : '${widget.tenantName} にチップ',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: Colors.black87,
                  ),
                ),
              ),
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // 金額表示
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.black12),
            ),
            child: Row(
              children: [
                const Text(
                  '¥',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '$_amount',
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      color: Colors.black87,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: () => _setAmount(0),
                  icon: const Icon(Icons.clear),
                  label: const Text('クリア'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // プリセット
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _presets.map((preset) {
              final isSelected = _amount == preset;
              return ChoiceChip(
                label: Text('¥$preset'),
                selected: isSelected,
                onSelected: (_) => _setAmount(preset),
                selectedColor: Colors.black,
                backgroundColor: Colors.grey[200],
                labelStyle: TextStyle(
                  color: isSelected ? Colors.white : Colors.black,
                  fontWeight: FontWeight.w600,
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 12),
          // キーパッド
          _Keypad(
            onTapDigit: _appendDigit,
            onTapDoubleZero: _appendDoubleZero,
            onBackspace: _backspace,
          ),
          const SizedBox(height: 12),
          // フッター
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _loading ? null : () => Navigator.pop(context),
                  child: const Text('キャンセル'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _loading ? null : _goToStripe,
                  icon: _loading
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.open_in_new),
                  label: const Text('Stripeへ進む'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Keypad extends StatelessWidget {
  final void Function(int digit) onTapDigit;
  final VoidCallback onTapDoubleZero;
  final VoidCallback onBackspace;

  const _Keypad({
    required this.onTapDigit,
    required this.onTapDoubleZero,
    required this.onBackspace,
  });

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 1.6,
      children: [
        for (var i = 1; i <= 9; i++) _buildButton('$i', () => onTapDigit(i)),
        _buildButton('00', onTapDoubleZero),
        _buildButton('0', () => onTapDigit(0)),
        _buildIconButton(Icons.backspace_outlined, onBackspace),
      ],
    );
  }

  Widget _buildButton(String label, VoidCallback onPressed) {
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(vertical: 14),
      ),
      child: Text(label, style: const TextStyle(fontSize: 18)),
    );
  }

  Widget _buildIconButton(IconData icon, VoidCallback onPressed) {
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(vertical: 14),
      ),
      child: Icon(icon, size: 22),
    );
  }
}
