import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:yourpay/appadmin/agent/agent_detail.dart';

class AgentLoginPage extends StatefulWidget {
  const AgentLoginPage({super.key});

  @override
  State<AgentLoginPage> createState() => _AgentLoginPageState();
}

class _AgentLoginPageState extends State<AgentLoginPage> {
  final _code = TextEditingController();
  final _pass = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final code = _code.text.trim();
    final pw = _pass.text;
    if (code.isEmpty || pw.isEmpty) {
      setState(() => _error = '紹介コードとパスワードを入力してください');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final fn = FirebaseFunctions.instanceFor(
        region: 'us-central1',
      ).httpsCallable('agentLogin');
      final res = await fn.call({'code': code, 'password': pw});
      final data = Map<String, dynamic>.from(res.data as Map);
      final token = data['token'] as String;
      final agentId = data['agentId'] as String;
      final agent = data["agent"] as bool;

      await FirebaseAuth.instance.signInWithCustomToken(token);

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => AgencyDetailPage(agentId: agentId, agent: agent),
        ),
      );
    } on FirebaseFunctionsException catch (e) {
      final msg = switch (e.code) {
        'not-found' => '紹介コードが見つかりません',
        'failed-precondition' => 'パスワード未設定/利用停止中の可能性があります',
        'permission-denied' => 'コードまたはパスワードが違います',
        _ => e.message ?? 'ログインに失敗しました (${e.code})',
      };
      setState(() => _error = msg);
    } catch (e) {
      setState(() => _error = 'ログインに失敗しました: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('代理店ログイン'),
        automaticallyImplyLeading: false,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: _code,
                  decoration: const InputDecoration(
                    labelText: '紹介コード',
                    border: OutlineInputBorder(),
                  ),
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _pass,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'パスワード',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _login(),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _busy ? null : _login,
                    child: _busy
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('ログイン'),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: Colors.red.shade700,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
