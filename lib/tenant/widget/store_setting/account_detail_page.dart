import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class AccountDetailScreen extends StatefulWidget {
  const AccountDetailScreen({super.key});
  @override
  State<AccountDetailScreen> createState() => _AccountDetailScreenState();
}

class _AccountDetailScreenState extends State<AccountDetailScreen> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _company = TextEditingController();

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final user = FirebaseAuth.instance.currentUser!;
    _name.text = user.displayName ?? '';
    _email.text = user.email ?? '';

    // Firestoreのユーザープロファイルを読み込み
    FirebaseFirestore.instance.collection('users').doc(user.uid).get().then((
      doc,
    ) {
      final d = doc.data();
      if (!mounted || d == null) return;
      _company.text = (d['companyName'] as String?) ?? _company.text;
      if ((d['displayName'] as String?)?.isNotEmpty == true &&
          _name.text.isEmpty) {
        _name.text = d['displayName'] as String;
      }
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _company.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final user = FirebaseAuth.instance.currentUser!;
    final newName = _name.text.trim();
    final newEmail = _email.text.trim();
    final newCompany = _company.text.trim();

    setState(() => _saving = true);
    try {
      // 名前の更新（Auth）
      if (newName != (user.displayName ?? '')) {
        await user.updateDisplayName(newName);
      }

      // メールの更新（Auth）※再認証が必要になることがあります
      if (newEmail.isNotEmpty && newEmail != (user.email ?? '')) {
        try {
          await user.updateEmail(newEmail);
          // 任意：確認メール
          await user.sendEmailVerification();
        } on FirebaseAuthException catch (e) {
          // requires-recent-login などはトースト表示
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('メール更新に失敗: ${e.code} ${e.message ?? ''}')),
          );
        }
      }

      // Firestore 側のプロファイル
      final uref = FirebaseFirestore.instance.collection('users').doc(user.uid);
      await uref.set({
        'displayName': newName,
        'email': newEmail,
        'companyName': newCompany,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('保存しました')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('保存に失敗: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final primaryBtnStyle = FilledButton.styleFrom(
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    );

    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 0,
        title: const Text(
          'アカウント',
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _FieldCard(
                title: '基本情報',
                child: Column(
                  children: [
                    TextField(
                      controller: _name,
                      decoration: const InputDecoration(labelText: '名前'),
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _email,
                      decoration: const InputDecoration(labelText: 'メールアドレス'),
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _company,
                      decoration: const InputDecoration(labelText: '会社名'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  style: primaryBtnStyle,
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.save),
                  label: const Text('保存する'),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '※ メール更新は再ログインが必要になる場合があります（requires-recent-login）。',
                style: TextStyle(color: Colors.black54, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FieldCard extends StatelessWidget {
  final String title;
  final Widget child;
  const _FieldCard({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1A000000),
            blurRadius: 16,
            offset: Offset(0, 8),
          ),
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}
