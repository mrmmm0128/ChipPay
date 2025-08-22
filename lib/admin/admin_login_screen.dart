// lib/admin/admin_login_screen.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class AdminLoginScreen extends StatefulWidget {
  const AdminLoginScreen({super.key});
  @override
  State<AdminLoginScreen> createState() => _AdminLoginScreenState();
}

class _AdminLoginScreenState extends State<AdminLoginScreen> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  InputDecoration _input(
    String label, {
    Widget? prefixIcon,
    Widget? suffixIcon,
  }) {
    return InputDecoration(
      labelText: label,
      prefixIcon: prefixIcon,
      suffixIcon: suffixIcon,
      labelStyle: const TextStyle(color: Colors.black87),
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: Colors.grey.shade300),
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

  Future<bool> _isAdmin(User user) async {
    // 1) カスタムクレーム
    final token = await user.getIdTokenResult(true);
    final claims = token.claims ?? {};
    final claimOk = (claims['isAdmin'] == true) || (claims['role'] == 'admin');
    if (claimOk) return true;

    // 2) Firestore admins/{uid}
    final snap = await FirebaseFirestore.instance
        .collection('admins')
        .doc(user.uid)
        .get();
    if (snap.exists) {
      final data = snap.data()!;
      return (data['active'] as bool?) ?? true;
    }
    return false;
  }

  Future<void> _signIn() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final cred = await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: _email.text.trim(),
        password: _password.text,
      );
      final user = cred.user!;
      final ok = await _isAdmin(user);
      if (!ok) {
        await FirebaseAuth.instance.signOut();
        setState(() => _error = '管理者権限がありません。');
        return;
      }
      if (!mounted) return;
      Navigator.pushReplacementNamed(context, '/admin');
    } on FirebaseAuthException catch (e) {
      setState(() => _error = e.message ?? 'ログインに失敗しました。');
    } catch (e) {
      setState(() => _error = 'ログインに失敗しました: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final primaryBtnStyle = FilledButton.styleFrom(
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      padding: const EdgeInsets.symmetric(vertical: 14),
    );

    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        automaticallyImplyLeading: false,
        elevation: 0,
        title: const Text(
          '運営ログイン',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Card(
              elevation: 6,
              shadowColor: Colors.black26,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Form(
                  key: _form,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(height: 6),
                      TextFormField(
                        controller: _email,
                        decoration: _input(
                          'Email',
                          prefixIcon: const Icon(Icons.email_outlined),
                        ),
                        style: const TextStyle(color: Colors.black87),
                        cursorColor: Colors.black,
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
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _password,
                        decoration: _input(
                          'パスワード',
                          prefixIcon: const Icon(Icons.lock_outline),
                        ),
                        style: const TextStyle(color: Colors.black87),
                        cursorColor: Colors.black,
                        obscureText: true,
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (_) {
                          if (_form.currentState!.validate()) _signIn();
                        },
                        validator: (v) {
                          if (v == null || v.isEmpty) return 'パスワードを入力してください';
                          if (v.length < 6) return '6文字以上で入力してください';
                          return null;
                        },
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          _error!,
                          style: const TextStyle(color: Colors.red),
                        ),
                      ],
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          style: primaryBtnStyle,
                          onPressed: _loading
                              ? null
                              : () {
                                  if (_form.currentState!.validate()) _signIn();
                                },
                          child: _loading
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Text('ログイン'),
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
    );
  }
}
