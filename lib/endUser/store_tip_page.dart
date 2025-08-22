import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:yourpay/endUser/tip_waiting_page.dart';

class StoreTipPage extends StatefulWidget {
  final String tenantId;
  final String? tenantName;
  const StoreTipPage({super.key, required this.tenantId, this.tenantName});

  @override
  State<StoreTipPage> createState() => _StoreTipPageState();
}

class _StoreTipPageState extends State<StoreTipPage> {
  final _formKey = GlobalKey<FormState>();
  final _amountCtrl = TextEditingController();
  bool _loading = false;

  @override
  void dispose() {
    _amountCtrl.dispose();
    super.dispose();
  }

  Future<void> _sendStoreTip() async {
    if (!_formKey.currentState!.validate()) return;
    final amount = int.tryParse(_amountCtrl.text) ?? 0;
    if (amount <= 0) return;

    setState(() => _loading = true);
    try {
      // 店舗向けセッション作成
      final callable = FirebaseFunctions.instance.httpsCallable(
        'createStoreTipSessionPublic',
      );
      final result = await callable.call({
        'tenantId': widget.tenantId,
        'amount': amount,
        'memo': 'Tip to tenant',
      });

      final data = (result.data as Map);
      final checkoutUrl = data['checkoutUrl'] as String;

      // できれば Functions 側で返ってくる sessionId を使う
      String? sessionId = data['sessionId'] as String?;

      // フォールバック: URL から cs_... を抜き出して sessionId を推測
      String? _guessSessionIdFromUrl(String url) {
        final m = RegExp(r'(cs_(?:test_|live_)?[A-Za-z0-9]+)').firstMatch(url);
        return m?.group(1);
      }

      sessionId ??= _guessSessionIdFromUrl(checkoutUrl);

      // Stripe Checkout を外部で開く（別タブ/別ウィンドウ）
      await launchUrlString(checkoutUrl, mode: LaunchMode.externalApplication);

      if (!mounted) return;

      if (sessionId == null) {
        // 監視できない場合の保険（Functions の戻り値を sessionId 付きにしてね）
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('セッションIDが取得できませんでした。決済完了後に自動遷移しない場合は戻るを押してください。'),
          ),
        );
        return;
      }

      // ★ 先ほど作った待ち画面へ。Webhook が paid/failed に更新 → 自動で完了/失敗へ遷移
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => TipWaitingPage(
            sessionId: sessionId!,
            tenantId: widget.tenantId,
            tenantName: widget.tenantName,
            amount: amount,
            employeeName: null, // 店舗向けなので null
            checkoutUrl: checkoutUrl,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('エラー: $e')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = '${widget.tenantName ?? "お店"} にチップ';
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('お店: ${widget.tenantName ?? widget.tenantId}'),
              const SizedBox(height: 12),
              TextFormField(
                controller: _amountCtrl,
                decoration: const InputDecoration(labelText: '金額 (JPY)'),
                keyboardType: TextInputType.number,
                validator: (v) {
                  final n = int.tryParse((v ?? '').trim());
                  if (n == null || n <= 0) return '金額を入力してください';
                  return null;
                },
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _loading ? null : _sendStoreTip,
                  child: _loading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('チップを送信'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
