import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle; // ★ 追加：規約本文読み込み
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher_string.dart';

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
  final _nameCtrl = TextEditingController();
  final _companyCtrl = TextEditingController();
  Map<String, dynamic>? _args;

  bool _loading = false;
  bool _isSignUp = false;
  bool _showPass = false;
  bool _showPass2 = false;
  String? _error;

  bool _agreeTerms = false;
  bool _agreePrivacy = false; // ★ 追加：プライバシー同意
  bool _rememberMe = true;

  @override
  void initState() {
    super.initState();
    _email.addListener(_clearErrorOnType);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _args ??=
        ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
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

  // ───────────────────────── 規約/ポリシー本文表示（モーダル）
  Future<void> _openMarkdownAsset(String assetPath, String title) async {
    final text = await rootBundle.loadString(assetPath);
    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        final height = MediaQuery.of(ctx).size.height * 0.85;
        return SizedBox(
          height: height,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                child: Row(
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        fontFamily: "LINEseed",
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: () => Navigator.pop(ctx),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: Markdown(
                  data: text,
                  selectable: true, // テキスト選択可
                  padding: const EdgeInsets.all(16),
                  onTapLink: (text, href, title) {
                    if (href != null)
                      launchUrlString(
                        href,
                        mode: LaunchMode.externalApplication,
                      );
                  },
                  styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(ctx))
                      .copyWith(
                        h1: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                        ),
                        h2: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                        h3: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                        blockquoteDecoration: BoxDecoration(
                          border: Border(
                            left: BorderSide(color: Colors.black26, width: 3),
                          ),
                        ),
                      ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _openTerms() =>
      _openMarkdownAsset('assets/policies/terms_ja.md', '利用規約');
  Future<void> _openPrivacy() =>
      _openMarkdownAsset('assets/policies/privacy_ja.md', 'プライバシーポリシー');

  // ───────────────────────── Firestore プロファイル
  Future<void> _ensureUserDocExists({bool acceptedNow = false}) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final uid = user.uid;
    final docRef = FirebaseFirestore.instance.collection('users').doc(uid);
    final snap = await docRef.get();

    // 規約・ポリシーのバージョン（必要に応じて更新）
    const termsVersion = '2025-09-19';
    const privacyVersion = '2025-09-19';

    if (!snap.exists) {
      await docRef.set({
        'displayName': user.displayName ?? _nameCtrl.text.trim(),
        'email': user.email,
        'companyName': _companyCtrl.text.trim(),
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        if (acceptedNow) ...{
          'acceptedTermsAt': FieldValue.serverTimestamp(),
          'acceptedTermsVersion': termsVersion,
          'acceptedPrivacyAt': FieldValue.serverTimestamp(),
          'acceptedPrivacyVersion': privacyVersion,
        },
      }, SetOptions(merge: true));
    } else {
      await docRef.set({
        'updatedAt': FieldValue.serverTimestamp(),
        if (acceptedNow) ...{
          'acceptedTermsAt': FieldValue.serverTimestamp(),
          'acceptedTermsVersion': termsVersion,
          'acceptedPrivacyAt': FieldValue.serverTimestamp(),
          'acceptedPrivacyVersion': privacyVersion,
        },
      }, SetOptions(merge: true));
    }
  }

  Future<void> _showVerifyDialog({String? email}) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('メール認証が必要です'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              email != null
                  ? '「$email」に送った認証メールのリンクを開いてください。'
                  : '登録したメールアドレスに送った認証メールのリンクを開いてください。',
            ),
            const SizedBox(height: 8),
            const Text(
              'リンクを開いた後は、この画面で再度メールとパスワードを入力してログインしてください。',
              style: TextStyle(color: Colors.black54, fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _sendVerificationEmail([User? u]) async {
    final user = u ?? FirebaseAuth.instance.currentUser;
    if (user == null) return;
    await user.sendEmailVerification();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('確認メールを送信しました。メール内のリンクで認証してください。')),
    );
  }

  Future<void> _resendVerifyManually() async {
    final email = _email.text.trim();
    final pass = _pass.text;
    if (email.isEmpty || pass.isEmpty) {
      setState(() => _error = '「Email」と「Password」を入力してください（再送には必要です）');
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
      final cred = await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email,
        password: pass,
      );
      await _sendVerificationEmail(cred.user);
      await _showVerifyDialog(email: email);
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      setState(() => _error = _friendlyAuthError(e));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      try {
        await FirebaseAuth.instance.signOut();
      } catch (_) {}
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    // ★ 同意両方必須
    if (_isSignUp && (!(_agreeTerms) || !(_agreePrivacy))) {
      setState(() => _error = '利用規約とプライバシーポリシーに同意してください');
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

        // ★ 同意記録（初回作成時）
        await _ensureUserDocExists(acceptedNow: true);

        await _sendVerificationEmail(cred.user);
        await _showVerifyDialog(email: _email.text.trim());
        await FirebaseAuth.instance.signOut();

        if (!mounted) return;
        setState(() => _isSignUp = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('登録しました。認証後にログインしてください。')));
        return;
      } else {
        // ログイン
        final cred = await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: _email.text.trim(),
          password: _pass.text,
        );

        User? user = cred.user;
        if (user == null) return;

        try {
          await user.getIdToken(true);
          await Future.delayed(const Duration(milliseconds: 300));
          await user.reload();
          user = FirebaseAuth.instance.currentUser;
        } catch (_) {}

        if (user == null || !user.emailVerified) {
          await _sendVerificationEmail(user);
          await _showVerifyDialog(email: _email.text.trim());
          await FirebaseAuth.instance.signOut();
          if (!mounted) return;
          setState(() => _error = null);
          return;
        }

        // 認証済み → プロファイル整備（ログイン時は acceptedNow: false）
        await _ensureUserDocExists(acceptedNow: false);

        // 直遷移指定があれば
        final returnTo = _args?['returnTo'] as String?;
        if (returnTo != null) {
          if (Navigator.of(context).canPop()) {
            Navigator.of(context).pop();
          } else {
            Navigator.of(context).pushReplacementNamed(
              returnTo,
              arguments: {
                'tenantId': _args?['tenantId'],
                'token': _args?['token'],
              },
            );
          }
          return;
        }
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
        return 'ログイン情報が認証されませんでした。';
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
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = MediaQuery.of(context).size.width;
              final bottomInset = MediaQuery.of(context).viewInsets.bottom;

              return SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: EdgeInsets.only(bottom: bottomInset),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Center(
                    child: Column(
                      mainAxisAlignment:
                          MainAxisAlignment.center, // ← 初期位置は従来どおり中央
                      children: [
                        const SizedBox(height: 10),
                        Image.asset(
                          "assets/posters/tipri.png",
                          width: width / 5,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          "チップを通じて、より良い接客・ホスピタリティを実現しませんか？",
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: width / 40,
                            fontFamily: "LINEseed",
                          ),
                        ),
                        const SizedBox(height: 8),

                        // ここから下は元のフォームの中身をそのまま使用
                        Padding(
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
                              padding: const EdgeInsets.fromLTRB(
                                20,
                                20,
                                20,
                                16,
                              ),
                              child: Form(
                                key: _formKey,
                                child: AutofillGroup(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      const SizedBox(height: 10),
                                      Row(
                                        children: [
                                          Container(
                                            decoration: BoxDecoration(
                                              color: Colors.black,
                                              borderRadius:
                                                  BorderRadius.circular(10),
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
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
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
                                          prefixIcon: const Icon(
                                            Icons.email_outlined,
                                          ),
                                        ),
                                        style: const TextStyle(
                                          color: Colors.black87,
                                        ),
                                        keyboardType:
                                            TextInputType.emailAddress,
                                        textInputAction: TextInputAction.next,
                                        autofillHints: const [
                                          AutofillHints.username,
                                          AutofillHints.email,
                                        ],
                                        validator: (v) {
                                          if (v == null || v.trim().isEmpty) {
                                            return 'メールを入力してください';
                                          }
                                          if (!v.contains('@'))
                                            return 'メール形式が不正です';
                                          return null;
                                        },
                                      ),
                                      const SizedBox(height: 10),

                                      TextFormField(
                                        controller: _pass,
                                        style: const TextStyle(
                                          color: Colors.black87,
                                        ),
                                        decoration: _input(
                                          'Password',
                                          required: true,
                                          prefixIcon: const Icon(
                                            Icons.lock_outline,
                                          ),
                                          suffixIcon: IconButton(
                                            onPressed: () => setState(
                                              () => _showPass = !_showPass,
                                            ),
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
                                        autofillHints: const [
                                          AutofillHints.password,
                                        ],
                                        validator: _validatePassword,
                                        onEditingComplete: _isSignUp
                                            ? null
                                            : _submit,
                                      ),

                                      if (_isSignUp) ...[
                                        const SizedBox(height: 8),
                                        TextFormField(
                                          controller: _passConfirm,
                                          style: const TextStyle(
                                            color: Colors.black87,
                                          ),
                                          decoration: _input(
                                            'Confirm Password',
                                            required: true,
                                            prefixIcon: const Icon(
                                              Icons.lock_outline,
                                            ),
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
                                          decoration: _input(
                                            '名前（表示名）',
                                            required: true,
                                          ),
                                          style: const TextStyle(
                                            color: Colors.black87,
                                          ),
                                          validator: (v) {
                                            if (_isSignUp &&
                                                (v == null ||
                                                    v.trim().isEmpty)) {
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
                                          crossAxisAlignment:
                                              CrossAxisAlignment.center,
                                          children: [
                                            Checkbox(
                                              value: _rememberMe,
                                              onChanged: _loading
                                                  ? null
                                                  : (v) => setState(
                                                      () => _rememberMe =
                                                          v ?? true,
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
                                                style: TextStyle(
                                                  color: Colors.black87,
                                                ),
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
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Checkbox(
                                              value: _agreeTerms,
                                              onChanged: _loading
                                                  ? null
                                                  : (v) => setState(
                                                      () => _agreeTerms =
                                                          v ?? false,
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
                                                            TextDecoration
                                                                .underline,
                                                        color: Colors.black,
                                                        fontWeight:
                                                            FontWeight.w600,
                                                      ),
                                                      recognizer:
                                                          TapGestureRecognizer()
                                                            ..onTap =
                                                                _openTerms,
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 8),
                                        Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Checkbox(
                                              value: _agreePrivacy,
                                              onChanged: _loading
                                                  ? null
                                                  : (v) => setState(
                                                      () => _agreePrivacy =
                                                          v ?? false,
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
                                                      text:
                                                          'プライバシーポリシーに同意します（必須）\n',
                                                    ),
                                                    TextSpan(
                                                      text: 'プライバシーポリシーを読む',
                                                      style: const TextStyle(
                                                        decoration:
                                                            TextDecoration
                                                                .underline,
                                                        color: Colors.black,
                                                        fontWeight:
                                                            FontWeight.w600,
                                                      ),
                                                      recognizer:
                                                          TapGestureRecognizer()
                                                            ..onTap =
                                                                _openPrivacy,
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
                                            borderRadius: BorderRadius.circular(
                                              10,
                                            ),
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
                                        style: FilledButton.styleFrom(
                                          backgroundColor: Colors.black,
                                          foregroundColor: Colors.white,
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                          ),
                                          padding: const EdgeInsets.symmetric(
                                            vertical: 14,
                                          ),
                                        ),
                                        onPressed: _loading
                                            ? null
                                            : (_isSignUp &&
                                                      (!(_agreeTerms) ||
                                                          !(_agreePrivacy))
                                                  ? null
                                                  : _submit),
                                        child: _loading
                                            ? const SizedBox(
                                                height: 18,
                                                width: 18,
                                                child:
                                                    CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                    ),
                                              )
                                            : Text(
                                                _isSignUp ? 'アカウント作成' : 'ログイン',
                                              ),
                                      ),

                                      const SizedBox(height: 8),

                                      if (!_isSignUp)
                                        Row(
                                          children: [
                                            TextButton(
                                              onPressed: _loading
                                                  ? null
                                                  : _resendVerifyManually,
                                              style: TextButton.styleFrom(
                                                foregroundColor: Colors.black87,
                                              ),
                                              child: const Text('認証メールを再送'),
                                            ),
                                            const Spacer(),
                                            TextButton(
                                              onPressed: _loading
                                                  ? null
                                                  : _sendResetEmail,
                                              style: TextButton.styleFrom(
                                                foregroundColor: Colors.black87,
                                              ),
                                              child: const Text(
                                                'パスワードをお忘れですか？',
                                              ),
                                            ),
                                          ],
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
              );
            },
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
