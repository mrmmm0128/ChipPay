import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _pass = TextEditingController();
  final _passConfirm = TextEditingController();

  bool _loading = false;
  bool _isSignUp = false; // ← これでログイン/登録をトグル
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _pass.dispose();
    _passConfirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      if (_isSignUp) {
        // 新規登録
        final cred = await FirebaseAuth.instance.createUserWithEmailAndPassword(
          email: _email.text.trim(),
          password: _pass.text,
        );
        // （任意）メール確認を送りたい場合
        await cred.user?.sendEmailVerification();

        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('登録しました。確認メールを送信しました。')));
        // 登録直後にそのまま使うならホームへ遷移する場合は↓
        // Navigator.pushReplacementNamed(context, '/');
      } else {
        // ログイン
        await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: _email.text.trim(),
          password: _pass.text,
        );
        if (!mounted) return;
        // ログイン or 新規登録 成功直後の遷移先を変更
        Navigator.pushReplacementNamed(context, '/stores');
      }
    } on FirebaseAuthException catch (e) {
      setState(() => _error = _friendlyAuthError(e));
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
        return 'パスワードが弱すぎます（6文字以上にしてください）';
      case 'too-many-requests':
        return 'リクエストが多すぎます。しばらくしてからお試しください';
      default:
        return e.message ?? 'エラーが発生しました';
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = _isSignUp ? '新規登録' : 'ログイン';
    final actionLabel = _isSignUp ? 'アカウント作成' : 'Sign in';

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title, style: const TextStyle(fontSize: 22)),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _email,
                      decoration: const InputDecoration(labelText: 'Email'),
                      keyboardType: TextInputType.emailAddress,
                      validator: (v) {
                        if (v == null || v.trim().isEmpty)
                          return 'メールを入力してください';
                        if (!v.contains('@')) return 'メール形式が不正です';
                        return null;
                      },
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _pass,
                      decoration: const InputDecoration(labelText: 'Password'),
                      obscureText: true,
                      validator: (v) {
                        if (v == null || v.isEmpty) return 'パスワードを入力してください';
                        if (v.length < 6) return '6文字以上で入力してください';
                        return null;
                      },
                    ),
                    if (_isSignUp) ...[
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _passConfirm,
                        decoration: const InputDecoration(
                          labelText: 'Password（確認）',
                        ),
                        obscureText: true,
                        validator: (v) {
                          if (!_isSignUp) return null;
                          if (v == null || v.isEmpty)
                            return '確認用パスワードを入力してください';
                          if (v != _pass.text) return 'パスワードが一致しません';
                          return null;
                        },
                      ),
                    ],
                    const SizedBox(height: 16),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          _error!,
                          style: const TextStyle(color: Colors.red),
                        ),
                      ),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton(
                            onPressed: _loading ? null : _submit,
                            child: _loading
                                ? const SizedBox(
                                    height: 16,
                                    width: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Text(actionLabel),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // ログイン時のみ：パスワード再設定
                    if (!_isSignUp)
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: _loading ? null : _sendResetEmail,
                          child: const Text('パスワードをお忘れですか？'),
                        ),
                      ),
                    // トグル：ログイン <-> 新規登録
                    TextButton(
                      onPressed: _loading
                          ? null
                          : () => setState(() => _isSignUp = !_isSignUp),
                      child: Text(
                        _isSignUp ? '既にアカウントをお持ちですか？ログイン' : 'はじめての方はこちら（新規登録）',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
