import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/gestures.dart';
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
  // 追加: 名前・会社名
  final _nameCtrl = TextEditingController();
  final _companyCtrl = TextEditingController();
  final uid = FirebaseAuth.instance.currentUser?.uid;

  @override
  void dispose() {
    _email.dispose();
    _pass.dispose();
    _passConfirm.dispose();
    _nameCtrl.dispose();
    _companyCtrl.dispose();
    super.dispose();
  }

  bool _loading = false;
  bool _isSignUp = false; // ログイン/登録のトグル
  bool _showPass = false;
  bool _showPass2 = false;
  String? _error;

  // ★ 規約チェック（登録時は必須）
  bool _agreeTerms = false;

  // ★ 追加：ログイン状態を保持（Web のみ実動作。ネイティブは常に保持）
  bool _rememberMe = true;

  // ★ 必須ラベル（黒色アスタリスク）
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
            style: TextStyle(color: Colors.black), // 必須の色は黒
          ),
        ],
      ),
    );
  }

  Future<void> _goToFirstTenantOrStore() async {
    final qs = await FirebaseFirestore.instance.collection(uid!).limit(1).get();

    if (!mounted) return;

    if (qs.docs.isNotEmpty) {
      final d = qs.docs.first.data();
      Navigator.pushReplacementNamed(
        context,
        '/store',
        arguments: {'tenantId': qs.docs.first.id, 'tenantName': d['name']},
      );
    } else {
      Navigator.pushReplacementNamed(context, '/store');
    }
  }

  // ★ パスワードバリデーション（8文字以上・英字と数字を含む／記号は可）
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
      await FirebaseAuth.instance.setPersistence(
        _rememberMe ? Persistence.LOCAL : Persistence.SESSION,
      );

      if (_isSignUp) {
        final cred = await FirebaseAuth.instance.createUserWithEmailAndPassword(
          email: _email.text.trim(),
          password: _pass.text,
        );
        // 表示名を更新
        if (_nameCtrl.text.trim().isNotEmpty) {
          await cred.user?.updateDisplayName(_nameCtrl.text.trim());
        }
        // Firestore プロファイル
        final uid = cred.user!.uid;
        await FirebaseFirestore.instance.collection('users').doc(uid).set({
          'displayName': _nameCtrl.text.trim(),
          'email': _email.text.trim(),
          'companyName': _companyCtrl.text.trim(),
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));

        // 確認メール送信
        await cred.user?.sendEmailVerification();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              '登録しました。確認メールを送信しました。メール認証後にログインできます。',
              style: TextStyle(fontFamily: 'LINEseed'),
            ),
          ),
        );
        // 登録直後はログインさせない
      } else {
        final cred = await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: _email.text.trim(),
          password: _pass.text,
        );

        // メール未確認はログインさせない
        final user = cred.user;
        if (user != null && !user.emailVerified) {
          await user.sendEmailVerification();
          await FirebaseAuth.instance.signOut();
          if (!mounted) return;
          setState(
            () =>
                _error = 'メール認証が未完了です。受信箱を確認し、メール内のリンクで認証してください。確認メールを再送しました。',
          );
          return;
        }

        if (!mounted) return;
        _goToFirstTenantOrStore();
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'パスワード再設定メールを送信しました。',
            style: TextStyle(fontFamily: 'LINEseed'),
          ),
        ),
      );
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
        return 'パスワードが弱すぎます（8文字以上・英字と数字の組み合わせ）';
      case 'too-many-requests':
        return 'メールアドレスを認証してください';
      default:
        return e.message ?? 'エラーが発生しました';
    }
  }

  // ★ 必須対応のInputDecoration
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
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Colors.black, width: 1.2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Colors.red),
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

    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: Scaffold(
        backgroundColor: Colors.grey[100],
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
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
                        spreadRadius: 0,
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
                          // ヘッダー
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
                                  fontFamily: 'LINEseed',
                                  fontWeight: FontWeight.w600,
                                  color: Colors.black87,
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(height: 12),
                          Center(
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 28,
                                  height: 28,
                                  decoration: BoxDecoration(
                                    color: Colors.black,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: const Icon(
                                    Icons.qr_code,
                                    color: Colors.white,
                                    size: 18,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                const Text(
                                  'Tipri',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    fontFamily: 'LINEseed',
                                    color: Colors.black87,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),

                          // トグル（ログイン / 新規登録）
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
                                        : () =>
                                              setState(() => _isSignUp = false),
                                  ),
                                  _ModeChip(
                                    label: '新規登録',
                                    active: _isSignUp,
                                    onTap: _loading
                                        ? null
                                        : () =>
                                              setState(() => _isSignUp = true),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),

                          // 入力欄
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
                              if (v == null || v.trim().isEmpty) {
                                return 'メールを入力してください';
                              }
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
                                  onPressed: () =>
                                      setState(() => _showPass2 = !_showPass2),
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

                          // ★ 追加：ログイン時のみ「ログイン状態を保持する」
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
                                  side: const BorderSide(color: Colors.black54),
                                  checkColor: Colors.white,
                                  activeColor: Colors.black,
                                ),
                                const SizedBox(width: 4),
                                const Expanded(
                                  child: Text(
                                    'ログイン状態を保持する',
                                    style: TextStyle(
                                      color: Colors.black87,
                                      fontFamily: 'LINEseed',
                                    ),
                                  ),
                                ),

                                const Tooltip(
                                  message:
                                      'オン：ブラウザを閉じてもログイン維持\nオフ：このタブ/ウィンドウを閉じるとログアウト',
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
                                  side: const BorderSide(color: Colors.black54),
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
                                            fontFamily: 'LINEseed',
                                          ),
                                          recognizer: TapGestureRecognizer()
                                            ..onTap = () {
                                              // TODO: 規約ページへ遷移
                                            },
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],

                          const SizedBox(height: 14),

                          // エラーバナー
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
                                crossAxisAlignment: CrossAxisAlignment.start,
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
                                        fontFamily: 'LINEseed',
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),

                          const SizedBox(height: 14),

                          // 送信ボタン
                          FilledButton(
                            style: primaryBtnStyle,
                            onPressed: _loading
                                ? null
                                : (_isSignUp && !_agreeTerms ? null : _submit),
                            child: _loading
                                ? const SizedBox(
                                    height: 18,
                                    width: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Text(
                                    actionLabel,
                                    style: TextStyle(fontFamily: 'LINEseed'),
                                  ),
                          ),

                          const SizedBox(height: 8),

                          // ログイン時のみ：パスワード再設定
                          if (!_isSignUp)
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton(
                                onPressed: _loading ? null : _sendResetEmail,
                                style: TextButton.styleFrom(
                                  foregroundColor: Colors.black87,
                                ),
                                child: const Text(
                                  'パスワードをお忘れですか？',
                                  style: TextStyle(fontFamily: 'LINEseed'),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
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
              fontFamily: 'LINEseed',
            ),
          ),
        ),
      ),
    );
  }
}
