import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AcceptInviteScreen extends StatefulWidget {
  const AcceptInviteScreen({super.key});
  @override
  State<AcceptInviteScreen> createState() => _AcceptInviteScreenState();
}

class _AcceptInviteScreenState extends State<AcceptInviteScreen> {
  // ★ Functions 名をここで統一（サーバに合わせて必要なら変更）
  static const String kAcceptFunctionName = 'acceptTenantAdminInvite';

  String? tenantId, token;
  String? result;
  bool busy = false;

  // パラメータ手入力用（URLに無い場合のフォールバック）
  final _tenantIdCtrl = TextEditingController();
  final _tokenCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _readParams();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _readParams();
  }

  void _readParams() {
    final base = Uri.base;

    // --- 既存: URL/フラグメント から取得 ---
    tenantId = base.queryParameters['tenantId'] ?? tenantId;
    token = base.queryParameters['token'] ?? token;

    if (tenantId == null || token == null) {
      final frag = base.fragment;
      final s = frag.startsWith('/') ? frag.substring(1) : frag;
      final f = Uri.tryParse(s);
      final qp = f?.queryParameters ?? const {};
      tenantId ??= qp['tenantId'];
      token ??= qp['token'];
    }

    // ★ 追加: ルート引数からも受け取る（/login からの復帰用）
    final routeArgs = ModalRoute.of(context)?.settings.arguments;
    if (routeArgs is Map) {
      tenantId ??= routeArgs['tenantId'] as String?;
      token ??= routeArgs['token'] as String?;
    }

    if (tenantId != null) _tenantIdCtrl.text = tenantId!;
    if (token != null) _tokenCtrl.text = token!;

    if (mounted) setState(() {});
  }

  bool get _hasParams =>
      (tenantId?.isNotEmpty ?? false) && (token?.isNotEmpty ?? false);

  String _mask(String? s, {int head = 6, int tail = 4}) {
    if (s == null || s.isEmpty) return '(なし)';
    if (s.length <= head + tail) return '•••';
    return '${s.substring(0, head)}•••${s.substring(s.length - tail)}';
  }

  Future<void> _copy(String label, String? value) async {
    if (value == null || value.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$label をコピーしました')));
  }

  Future<void> _accept() async {
    final user = FirebaseAuth.instance.currentUser;
    // 入力欄の値で上書き（URLに無い場合のフォールバックも含む）
    tenantId = (tenantId?.isNotEmpty ?? false)
        ? tenantId
        : _tenantIdCtrl.text.trim();
    token = (token?.isNotEmpty ?? false) ? token : _tokenCtrl.text.trim();

    if (user == null) {
      setState(() => result = 'まずログインしてください。');
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
      ).httpsCallable(kAcceptFunctionName);
      await fn.call({'tenantId': tenantId, 'token': token});

      if (!mounted) return;
      setState(() => result = '承認しました。店舗管理者として追加されました。');
    } on FirebaseFunctionsException catch (e) {
      final msg = switch (e.code) {
        'permission-denied' => '権限がありません（メール不一致の可能性）。',
        'invalid-argument' => 'リンクが不正または期限切れです。',
        'not-found' => '招待が見つかりません。',
        'failed-precondition' => 'この招待はすでに処理済みです。',
        'unauthenticated' => 'ログインが必要です。',
        _ => '承認に失敗: ${e.message ?? e.code}',
      };
      if (!mounted) return;
      setState(() => result = msg);
    } catch (e) {
      if (!mounted) return;
      setState(() => result = '承認に失敗: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('管理者招待を承認', style: TextStyle(fontFamily: 'LINEseed')),
        automaticallyImplyLeading: false,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // 招待情報カード
              Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: theme.dividerColor),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'リンク情報',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          const SizedBox(
                            width: 110,
                            child: Text(
                              'テナントID',
                              style: TextStyle(color: Colors.black54),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              tenantId ?? '(不明)',
                              style: const TextStyle(fontFamily: 'LINEseed'),
                            ),
                          ),
                          IconButton(
                            tooltip: 'テナントIDをコピー',
                            onPressed: tenantId == null
                                ? null
                                : () => _copy('テナントID', tenantId),
                            icon: const Icon(Icons.copy, size: 18),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      if (!_hasParams) ...[
                        const SizedBox(height: 12),
                        const Divider(),
                        const SizedBox(height: 12),
                        const Text('パラメータがURLから取得できませんでした。手入力してください。'),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _tenantIdCtrl,
                          decoration: const InputDecoration(
                            labelText: 'テナントID（必須）',
                            border: OutlineInputBorder(),
                          ),
                          onChanged: (v) => tenantId = v.trim(),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _tokenCtrl,
                          decoration: const InputDecoration(
                            labelText: 'トークン（必須）',
                            border: OutlineInputBorder(),
                          ),
                          onChanged: (v) => token = v.trim(),
                        ),
                      ],
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 12),

              // アカウント状態
              Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: theme.dividerColor),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      const Icon(Icons.account_circle, size: 28),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          user == null
                              ? '未ログインです。ログインして承認を続けてください。'
                              : 'ログイン中: ${user.email ?? user.uid}',
                          style: const TextStyle(fontFamily: 'LINEseed'),
                        ),
                      ),
                      if (user == null)
                        FilledButton(
                          onPressed: busy
                              ? null
                              : () {
                                  // ここであなたのログイン画面へ遷移（例）
                                  Navigator.of(context).pushNamed(
                                    '/login',
                                    arguments: {
                                      'returnTo': '/admin-invite', // 承認ページのルート名
                                      'tenantId': tenantId,
                                      'token': token,
                                    },
                                  );
                                },
                          child: const Text('ログイン'),
                        ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // アクション
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: busy ? null : _accept,
                      child: busy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(
                              user == null ? 'ログインして承認' : '承認する',
                              style: const TextStyle(fontFamily: 'LINEseed'),
                            ),
                    ),
                  ),
                ],
              ),

              if (result != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    border: Border.all(color: theme.dividerColor),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    result!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontFamily: 'LINEseed'),
                  ),
                ),
                const SizedBox(height: 8),
                if (result!.startsWith('承認しました')) ...[
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () {
                            // 例：トップへ戻る / 店舗画面へ
                            Navigator.of(
                              context,
                            ).pushReplacementNamed('/store');
                          },
                          child: const Text('店舗一覧へ'),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _tenantIdCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }
}
