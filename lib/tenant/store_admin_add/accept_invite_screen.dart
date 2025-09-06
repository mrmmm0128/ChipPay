import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class AcceptInviteScreen extends StatefulWidget {
  const AcceptInviteScreen({super.key});
  @override
  State<AcceptInviteScreen> createState() => _AcceptInviteScreenState();
}

class _AcceptInviteScreenState extends State<AcceptInviteScreen> {
  String? tenantId, token;
  String? result;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    _readParams();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // ルーティングで後から書き換わるケースに備えてもう一度読んでもOK
    _readParams();
  }

  void _readParams() {
    final base = Uri.base;

    // 1) https://example.com/?tenantId=...&token=... （#の前）
    tenantId = base.queryParameters['tenantId'] ?? tenantId;
    token = base.queryParameters['token'] ?? token;

    // 2) https://example.com/#/admin-invite?tenantId=...&token=... （#の中）
    if (tenantId == null || token == null) {
      final frag = base.fragment; // "/admin-invite?tenantId=...&token=..."
      final s = frag.startsWith('/')
          ? frag.substring(1)
          : frag; // "admin-invite?..."
      final f = Uri.tryParse(s);
      final qp = f?.queryParameters ?? const {};
      tenantId ??= qp['tenantId'];
      token ??= qp['token'];
    }

    if (mounted) setState(() {});
  }

  bool get _hasParams =>
      (tenantId?.isNotEmpty ?? false) && (token?.isNotEmpty ?? false);

  Future<void> _accept() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      setState(() => result = 'まずログインしてください。'); // 必要ならログイン画面へ誘導
      return;
    }
    if (!_hasParams) {
      setState(() => result = 'リンクが不正です。（tenantId / token が見つかりません）');
      return;
    }
    setState(() {
      busy = true;
      result = null;
    });
    try {
      final fn = FirebaseFunctions.instanceFor(
        region: 'us-central1',
      ).httpsCallable('acceptTenantAdmin');
      await fn.call({'tenantId': tenantId, 'token': token});

      setState(() => result = '承認しました。店舗管理者として追加されました。');
    } on FirebaseFunctionsException catch (e) {
      final msg = switch (e.code) {
        'permission-denied' => '権限がありません。',
        'invalid-argument' => 'リンクが不正または期限切れです。',
        'not-found' => '招待が見つかりません。',
        'failed-precondition' => 'この招待はすでに処理済みです。',
        _ => '承認に失敗: ${e.message ?? e.code}',
      };
      setState(() => result = msg);
    } catch (e) {
      setState(() => result = '承認に失敗: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    return Scaffold(
      appBar: AppBar(title: const Text('管理者招待を承認')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('テナント: ${tenantId ?? "(不明)"}'),
              const SizedBox(height: 8),
              if (!(_hasParams)) ...[
                const Text('リンクの形式が正しくない可能性があります。'),
                const SizedBox(height: 8),
              ],
              ElevatedButton(
                onPressed: busy ? null : _accept,
                child: busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(user == null ? 'ログインして承認' : '承認する'),
              ),
              if (result != null) ...[
                const SizedBox(height: 12),
                Text(result!, textAlign: TextAlign.center),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
