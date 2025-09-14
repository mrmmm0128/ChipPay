import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  // ★ 管理者メールのホワイトリスト（任意で追加）
  static const Set<String> _kAdminEmails = {'appfromkomeda@gmail.com'};

  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _pass = TextEditingController();
  final _passConfirm = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _companyCtrl = TextEditingController();

  bool _loading = false;
  bool _isSignUp = false;
  bool _showPass = false;
  bool _showPass2 = false;
  String? _error;

  bool _agreeTerms = false;
  bool _rememberMe = true;

  @override
  void initState() {
    super.initState();
    _email.addListener(_clearErrorOnType);
  }

  @override
  void dispose() {
    _email
      ..removeListener(_clearErrorOnType)
      ..dispose();
    _pass.dispose();
    _passConfirm.dispose();
    _nameCtrl.dispose();
    _companyCtrl.dispose();
    super.dispose();
  }

  void _clearErrorOnType() {
    if (_error != null) setState(() => _error = null);
  }

  Widget _requiredLabel(String text) {
    return RichText(
      text: TextSpan(
        children: [
          TextSpan(
            text: text,
            style: const TextStyle(color: Colors.black87),
          ),
          const TextSpan(
            text: ' *',
            style: TextStyle(color: Colors.black),
          ),
        ],
      ),
    );
  }

  Future<void> _goToFirstTenantOrStore() async {
    final currentUid = FirebaseAuth.instance.currentUser?.uid;
    if (currentUid == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('ログイン状態が確認できませんでした')));
      return;
    }
    try {
      final qs = await FirebaseFirestore.instance
          .collection(currentUid)
          .limit(1)
          .get();
      if (!mounted) return;

      if (qs.docs.isEmpty) {
        Navigator.pushReplacementNamed(context, '/store');
        return;
      }

      final firstDoc = qs.docs.first;
      final data = firstDoc.data();
      final tenantId = firstDoc.id;
      final tenantName = (data['name'] as String?)?.trim();

      Navigator.pushReplacementNamed(
        context,
        '/store',
        arguments: <String, dynamic>{
          'tenantId': tenantId,
          if (tenantName != null && tenantName.isNotEmpty)
            'tenantName': tenantName,
        },
      );
    } catch (_) {
      if (!mounted) return;
      Navigator.pushReplacementNamed(context, '/store');
    }
  }

  String? _validatePassword(String? v) {
    if (v == null || v.isEmpty) return 'パスワードを入力してください';
    if (v.length < 8) return '8文字以上で入力してください';
    final hasLetter = RegExp(r'[A-Za-z]').hasMatch(v);
    final hasDigit = RegExp(r'\d').hasMatch(v);
    if (!hasLetter || !hasDigit) {
      return '英字と数字を少なくとも1文字ずつ含めてください（記号は任意）';
    }
    return null;
  }

  String? _validatePasswordConfirm(String? v) {
    if (v == null || v.isEmpty) return '確認用パスワードを入力してください';
    if (v != _pass.text) return 'パスワードが一致しません';
    return null;
  }

  /// 認証後に Firestore の users/{uid} を初回作成
  Future<void> _ensureUserDocExists() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final uid = user.uid;
    final docRef = FirebaseFirestore.instance.collection('users').doc(uid);
    final snap = await docRef.get();
    if (!snap.exists) {
      await docRef.set({
        'displayName': user.displayName ?? _nameCtrl.text.trim(),
        'email': user.email,
        'companyName': _companyCtrl.text.trim(),
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } else {
      await docRef.set({
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    }
  }

  /// 認証メール送信
  Future<void> _sendVerificationEmail([User? u]) async {
    final user = u ?? FirebaseAuth.instance.currentUser;
    if (user == null) return;
    await user.sendEmailVerification();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('確認メールを送信しました。メール内のリンクで認証してください。')),
    );
  }

  /// ★ 管理者なら「管理 or 通常」を選ばせて遷移。一般はそのまま既存遷移
  Future<void> _routeAfterLogin(BuildContext context, User user) async {
    final email = (user.email ?? '').toLowerCase();
    final isAdmin = email == 'appfromkomeda@gmail.com'; // ← あなたの判定ロジック

    if (!isAdmin) {
      await _goToFirstTenantOrStore(); // 通常ルート
      return;
    }

    // ★ Web のフォーカス競合を避けるため、事前にアンフォーカス
    FocusManager.instance.primaryFocus?.unfocus();

    final choice = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        title: const Text('ログイン先を選択', style: TextStyle(color: Colors.black87)),
        content: const Text(
          '管理者アカウントとしてログインしています。どちらの画面に入りますか？',
          style: TextStyle(color: Colors.black87),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, 'normal'),
            child: const Text('通常画面', style: TextStyle(color: Colors.black87)),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(dialogCtx, 'admin'),
            icon: const Icon(Icons.admin_panel_settings),
            label: const Text('管理ダッシュボード'),
          ),
        ],
      ),
    );

    if (!context.mounted) return;

    // ★ ここがポイント：ダイアログ完全破棄を待って“次のフレーム”で遷移
    await Future<void>.delayed(const Duration(milliseconds: 10));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted) return;
      if (choice == 'admin') {
        Navigator.of(context).pushReplacementNamed('/admin');
      } else {
        _goToFirstTenantOrStore();
      }
    });
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    if (_isSignUp && !_agreeTerms) {
      setState(() => _error = '利用規約に同意してください');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      if (kIsWeb) {
        await FirebaseAuth.instance.setPersistence(
          _rememberMe ? Persistence.LOCAL : Persistence.SESSION,
        );
      }

      if (_isSignUp) {
        // 新規登録
        final cred = await FirebaseAuth.instance.createUserWithEmailAndPassword(
          email: _email.text.trim(),
          password: _pass.text,
        );

        final displayName = _nameCtrl.text.trim();
        if (displayName.isNotEmpty) {
          await cred.user?.updateDisplayName(displayName);
        }

        await _sendVerificationEmail(cred.user);
        await FirebaseAuth.instance.signOut();

        if (!mounted) return;
        setState(() => _isSignUp = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('登録しました。メールの確認リンクを開いた後、ログインしてください。')),
        );
        return;
      } else {
        // ログイン
        final cred = await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: _email.text.trim(),
          password: _pass.text,
        );

        final user = cred.user;
        if (user == null) return;

        await user.reload();
        if (!user.emailVerified) {
          await _sendVerificationEmail(user);
          await FirebaseAuth.instance.signOut();
          if (!mounted) return;
          setState(() => _error = 'メール認証が未完了です。');
          return;
        }

        // users/{uid} 作成・更新
        await _ensureUserDocExists();

        if (!mounted) return;
      }
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      setState(() => _error = _friendlyAuthError(e));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _sendResetEmail() async {
    final email = _email.text.trim();
    if (email.isEmpty) {
      setState(() => _error = 'パスワードリセットにはメールアドレスが必要です');
      return;
    }
    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('パスワード再設定メールを送信しました。')));
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      setState(() => _error = _friendlyAuthError(e));
    }
  }

  String _friendlyAuthError(FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-email':
        return 'メールアドレスの形式が正しくありません';
      case 'user-disabled':
        return 'このユーザーは無効化されています';
      case 'user-not-found':
        return 'ユーザーが見つかりません';
      case 'wrong-password':
        return 'パスワードが違います';
      case 'email-already-in-use':
        return 'このメールアドレスは既に登録されています';
      case 'weak-password':
        return 'パスワードが弱すぎます（8文字以上・英字と数字の組み合わせ）';
      case 'too-many-requests':
        return '試行回数が多すぎます。しばらくしてから再度お試しください。';
      default:
        return e.message ?? 'エラーが発生しました';
    }
  }

  InputDecoration _input(
    String label, {
    bool required = false,
    Widget? prefixIcon,
    Widget? suffixIcon,
    String? hintText,
    String? helperText,
  }) {
    return InputDecoration(
      label: required ? _requiredLabel(label) : null,
      labelText: required ? null : label,
      hintText: hintText,
      helperText: helperText,
      labelStyle: const TextStyle(color: Colors.black87),
      floatingLabelStyle: const TextStyle(color: Colors.black),
      hintStyle: const TextStyle(color: Colors.black54),
      prefixIcon: prefixIcon,
      suffixIcon: suffixIcon,
      prefixIconColor: Colors.black54,
      suffixIconColor: Colors.black54,
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: Colors.grey.shade300, width: 1),
      ),
      focusedBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(14)),
        borderSide: BorderSide(color: Colors.black, width: 1.2),
      ),
      errorBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(14)),
        borderSide: BorderSide(color: Colors.red),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = _isSignUp ? '新規登録' : 'ログイン';
    final actionLabel = _isSignUp ? 'アカウント作成' : 'ログイン';

    final primaryBtnStyle = FilledButton.styleFrom(
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      padding: const EdgeInsets.symmetric(vertical: 14),
    );
    final width = MediaQuery.of(context).size.width;

    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: Scaffold(
        backgroundColor: Colors.grey[100],
        body: SafeArea(
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Image.asset("assets/posters/tipri.png", width: width / 5),
                const SizedBox(height: 8),
                Text(
                  "チップを通じて、より良い接客・ホスピタリティを実現しませんか？",
                  style: TextStyle(
                    fontSize: width / 40,
                    fontFamily: "LINEseed",
                  ),
                ),
                const SizedBox(height: 8),
                SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 24,
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(18),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x1A000000),
                            blurRadius: 24,
                            offset: Offset(0, 12),
                          ),
                        ],
                      ),
                      padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
                      child: Form(
                        key: _formKey,
                        child: AutofillGroup(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const SizedBox(height: 10),

                              Row(
                                children: [
                                  Container(
                                    decoration: BoxDecoration(
                                      color: Colors.black,
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    padding: const EdgeInsets.all(8),
                                    child: const Icon(
                                      Icons.lock,
                                      color: Colors.white,
                                      size: 20,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Text(
                                    title,
                                    style: const TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.black87,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 16),

                              Align(
                                alignment: Alignment.centerLeft,
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Colors.grey[100],
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  padding: const EdgeInsets.all(4),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      _ModeChip(
                                        label: 'ログイン',
                                        active: !_isSignUp,
                                        onTap: _loading
                                            ? null
                                            : () => setState(
                                                () => _isSignUp = false,
                                              ),
                                      ),
                                      _ModeChip(
                                        label: '新規登録',
                                        active: _isSignUp,
                                        onTap: _loading
                                            ? null
                                            : () => setState(
                                                () => _isSignUp = true,
                                              ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 16),

                              TextFormField(
                                controller: _email,
                                decoration: _input(
                                  'Email',
                                  required: true,
                                  prefixIcon: const Icon(Icons.email_outlined),
                                ),
                                style: const TextStyle(color: Colors.black87),
                                keyboardType: TextInputType.emailAddress,
                                textInputAction: TextInputAction.next,
                                autofillHints: const [
                                  AutofillHints.username,
                                  AutofillHints.email,
                                ],
                                validator: (v) {
                                  if (v == null || v.trim().isEmpty)
                                    return 'メールを入力してください';
                                  if (!v.contains('@')) return 'メール形式が不正です';
                                  return null;
                                },
                              ),
                              const SizedBox(height: 10),
                              TextFormField(
                                controller: _pass,
                                style: const TextStyle(color: Colors.black87),
                                decoration: _input(
                                  'Password',
                                  required: true,
                                  prefixIcon: const Icon(Icons.lock_outline),
                                  suffixIcon: IconButton(
                                    onPressed: () =>
                                        setState(() => _showPass = !_showPass),
                                    icon: Icon(
                                      _showPass
                                          ? Icons.visibility_off
                                          : Icons.visibility,
                                    ),
                                  ),
                                  helperText: '8文字以上・英字と数字を含む（記号可）',
                                ),
                                obscureText: !_showPass,
                                textInputAction: _isSignUp
                                    ? TextInputAction.next
                                    : TextInputAction.done,
                                autofillHints: const [AutofillHints.password],
                                validator: _validatePassword,
                                onEditingComplete: _isSignUp ? null : _submit,
                              ),

                              if (_isSignUp) ...[
                                const SizedBox(height: 8),
                                TextFormField(
                                  controller: _passConfirm,
                                  style: const TextStyle(color: Colors.black87),
                                  decoration: _input(
                                    'Confirm Password',
                                    required: true,
                                    prefixIcon: const Icon(Icons.lock_outline),
                                    suffixIcon: IconButton(
                                      onPressed: () => setState(
                                        () => _showPass2 = !_showPass2,
                                      ),
                                      icon: Icon(
                                        _showPass2
                                            ? Icons.visibility_off
                                            : Icons.visibility,
                                      ),
                                    ),
                                    helperText: '同じパスワードをもう一度入力してください',
                                  ),
                                  obscureText: !_showPass2,
                                  textInputAction: TextInputAction.next,
                                  validator: _validatePasswordConfirm,
                                ),
                                const SizedBox(height: 8),
                                TextFormField(
                                  controller: _nameCtrl,
                                  decoration: _input('名前（表示名）', required: true),
                                  style: const TextStyle(color: Colors.black87),
                                  validator: (v) {
                                    if (_isSignUp &&
                                        (v == null || v.trim().isEmpty)) {
                                      return '名前を入力してください';
                                    }
                                    return null;
                                  },
                                ),
                                const SizedBox(height: 8),
                              ],

                              if (!_isSignUp) ...[
                                const SizedBox(height: 8),
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    Checkbox(
                                      value: _rememberMe,
                                      onChanged: _loading
                                          ? null
                                          : (v) => setState(
                                              () => _rememberMe = v ?? true,
                                            ),
                                      side: const BorderSide(
                                        color: Colors.black54,
                                      ),
                                      checkColor: Colors.white,
                                      activeColor: Colors.black,
                                    ),
                                    const SizedBox(width: 4),
                                    const Expanded(
                                      child: Text(
                                        'ログイン状態を保持する',
                                        style: TextStyle(color: Colors.black87),
                                      ),
                                    ),
                                    const Tooltip(
                                      message:
                                          'オン：ブラウザを閉じてもログイン維持\nオフ：このタブ/ウィンドウを閉じるとログアウト（Webのみ）',
                                      child: Icon(
                                        Icons.info_outline,
                                        size: 18,
                                        color: Colors.black45,
                                      ),
                                    ),
                                  ],
                                ),
                              ],

                              if (_isSignUp) ...[
                                const SizedBox(height: 8),
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Checkbox(
                                      value: _agreeTerms,
                                      onChanged: _loading
                                          ? null
                                          : (v) => setState(
                                              () => _agreeTerms = v ?? false,
                                            ),
                                      side: const BorderSide(
                                        color: Colors.black54,
                                      ),
                                      checkColor: Colors.white,
                                      activeColor: Colors.black,
                                    ),
                                    const SizedBox(width: 4),
                                    Expanded(
                                      child: RichText(
                                        text: TextSpan(
                                          style: const TextStyle(
                                            color: Colors.black87,
                                            height: 1.4,
                                          ),
                                          children: [
                                            const TextSpan(
                                              text: '利用規約に同意します（必須）\n',
                                            ),
                                            TextSpan(
                                              text: '利用規約を読む',
                                              style: const TextStyle(
                                                decoration:
                                                    TextDecoration.underline,
                                                color: Colors.black,
                                                fontWeight: FontWeight.w600,
                                              ),
                                              recognizer: TapGestureRecognizer()
                                                ..onTap = () {},
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],

                              const SizedBox(height: 14),

                              if (_error != null)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 10,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFFFE8E8),
                                    borderRadius: BorderRadius.circular(10),
                                    boxShadow: const [
                                      BoxShadow(
                                        color: Color(0x14000000),
                                        blurRadius: 10,
                                        offset: Offset(0, 4),
                                      ),
                                    ],
                                  ),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const Icon(
                                        Icons.error_outline,
                                        color: Colors.red,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          _error!,
                                          style: const TextStyle(
                                            color: Colors.red,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),

                              const SizedBox(height: 14),

                              FilledButton(
                                style: primaryBtnStyle,
                                onPressed: _loading
                                    ? null
                                    : (_isSignUp && !_agreeTerms
                                          ? null
                                          : _submit),
                                child: _loading
                                    ? const SizedBox(
                                        height: 18,
                                        width: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : Text(actionLabel),
                              ),

                              const SizedBox(height: 8),

                              if (!_isSignUp)
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: TextButton(
                                    onPressed: _loading
                                        ? null
                                        : _sendResetEmail,
                                    style: TextButton.styleFrom(
                                      foregroundColor: Colors.black87,
                                    ),
                                    child: const Text('パスワードをお忘れですか？'),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback? onTap;
  const _ModeChip({required this.label, required this.active, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: active,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: active ? Colors.black : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(
            label,
            style: TextStyle(
              color: active ? Colors.white : Colors.black87,
              fontWeight: active ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}
