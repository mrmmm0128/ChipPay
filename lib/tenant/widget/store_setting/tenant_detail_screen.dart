import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class tenantDetailScreen extends StatefulWidget {
  const tenantDetailScreen({super.key});
  @override
  State<tenantDetailScreen> createState() => _AccountDetailScreenState();
}

class _AccountDetailScreenState extends State<tenantDetailScreen> {
  final _tenantName = TextEditingController();

  bool _saving = false;

  // テナント解決/ポータル起動用
  String? _tenantId; // ルート引数 or 自動推定
  bool _openingCustomerPortal = false;
  bool _openingConnectPortal = false;

  @override
  void initState() {
    super.initState();

    // 画面遷移の引数から tenantId が来ていれば採用
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final args = ModalRoute.of(context)?.settings.arguments;
      if (args is Map &&
          args['tenantId'] is String &&
          (args['tenantId'] as String).isNotEmpty) {
        _tenantId = args['tenantId'] as String;
        setState(() {});
        _loadTenantName();
      } else {
        _resolveFirstTenant(); // 自動推定 → 読み込み
      }
    });
  }

  Future<void> _resolveFirstTenant() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final qs = await FirebaseFirestore.instance
          .collection(user.uid)
          .limit(1)
          .get();
      if (qs.docs.isNotEmpty) {
        _tenantId = qs.docs.first.id;
        if (mounted) setState(() {});
        await _loadTenantName();
      }
    } catch (_) {}
  }

  Future<void> _loadTenantName() async {
    final user = FirebaseAuth.instance.currentUser;
    final tid = _tenantId;
    if (user == null || tid == null) return;
    try {
      final doc = await FirebaseFirestore.instance
          .collection(user.uid)
          .doc(tid)
          .get();
      final d = doc.data();
      if (!mounted || d == null) return;
      // name が無ければ displayName を後方互換で読む
      _tenantName.text =
          (d['name'] as String?) ??
          (d['displayName'] as String?) ??
          _tenantName.text;
    } catch (_) {
      // 読み込み失敗時は何もしない（空のまま）
    }
  }

  @override
  void dispose() {
    _tenantName.dispose();
    super.dispose();
  }

  Future<void> _saveTenant() async {
    final user = FirebaseAuth.instance.currentUser;
    final tid = _tenantId;
    if (user == null || tid == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('店舗が見つかりません')));
      return;
    }
    final newName = _tenantName.text.trim();
    if (newName.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('店舗名を入力してください')));
      return;
    }

    setState(() => _saving = true);
    try {
      final tref = FirebaseFirestore.instance.collection(user.uid).doc(tid);
      await tref.set({
        'name': newName,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('店舗名を保存しました')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('保存に失敗: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ===== Stripe: カスタマーポータル =====
  Future<void> _openCustomerPortal() async {
    final tid = _tenantId;
    if (tid == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('店舗が見つかりません')));
      return;
    }

    setState(() => _openingCustomerPortal = true);
    try {
      // 401対策：直前で ID トークンを強制更新してから callable 実行
      await FirebaseAuth.instance.currentUser?.getIdToken(true);

      final fn = FirebaseFunctions.instanceFor(
        region: 'us-central1',
      ).httpsCallable('createCustomerPortalSession');

      final resp = await fn.call({'tenantId': tid});
      final url = (resp.data as Map?)?['url'] as String?;
      if (url == null || url.isEmpty) {
        throw 'URLが取得できませんでした';
      }

      final ok = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
      if (!ok) throw 'ブラウザ起動に失敗しました';
    } on FirebaseFunctionsException catch (e) {
      final code = e.code;
      final msg = e.message ?? '';
      final friendly = switch (code) {
        'unauthenticated' => 'ログイン情報が無効です。再ログインしてお試しください。',
        'invalid-argument' => '必要な情報が不足しています（tenantId）。',
        'permission-denied' => '権限がありません。',
        _ => 'ポータル作成に失敗: $code $msg',
      };
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(friendly)));
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('エラー: $e')));
    } finally {
      if (mounted) setState(() => _openingCustomerPortal = false);
    }
  }

  // ===== Stripe: コネクトアカウント（口座確認/更新） =====
  Future<void> _openConnectPortal() async {
    final tid = _tenantId;
    if (tid == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('店舗が見つかりません')));
      return;
    }

    setState(() => _openingConnectPortal = true);
    try {
      // 401対策：直前で ID トークンを強制更新してから callable 実行
      await FirebaseAuth.instance.currentUser?.getIdToken(true);

      final fn = FirebaseFunctions.instanceFor(
        region: 'us-central1',
      ).httpsCallable('createConnectAccountLink');

      final resp = await fn.call({'tenantId': tid});
      final url = (resp.data as Map?)?['url'] as String?;
      if (url == null || url.isEmpty) {
        throw 'URLが取得できませんでした';
      }

      final ok = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
      if (!ok) throw 'ブラウザ起動に失敗しました';
    } on FirebaseFunctionsException catch (e) {
      final code = e.code;
      final msg = e.message ?? '';
      final friendly = switch (code) {
        'unauthenticated' => 'ログイン情報が無効です。再ログインしてお試しください。',
        'invalid-argument' => '必要な情報が不足しています（tenantId）。',
        'permission-denied' => '権限がありません。',
        _ => 'リンク作成に失敗: $code $msg',
      };
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(friendly)));
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('エラー: $e')));
    } finally {
      if (mounted) setState(() => _openingConnectPortal = false);
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
          '店舗設定',
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
                title: '店舗情報',
                child: Column(
                  children: [
                    TextField(
                      controller: _tenantName,
                      decoration: const InputDecoration(
                        labelText: '店舗名（テナント名）',
                      ),
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _saveTenant(),
                    ),
                    if (_tenantId == null)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text(
                          '※ 店舗が未選択のため編集できません。',
                          style: TextStyle(color: Colors.black54, fontSize: 12),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  style: primaryBtnStyle,
                  onPressed: (_tenantId == null || _saving)
                      ? null
                      : _saveTenant,
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
              const SizedBox(height: 24),

              // ===== Stripe 連携（そのまま残す） =====
              _FieldCard(
                title: 'Stripe 連携',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _StripeRow(
                      icon: Icons.receipt_long,
                      title: 'カスタマーポータル',
                      subtitle: 'サブスクリプション・初期費用の支払い状況を確認する。',
                      trailing: FilledButton(
                        onPressed: (_tenantId == null || _openingCustomerPortal)
                            ? null
                            : _openCustomerPortal,
                        child: _openingCustomerPortal
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('開く'),
                      ),
                    ),
                    const SizedBox(height: 10),
                    _StripeRow(
                      icon: Icons.account_balance,
                      title: 'コネクトアカウント',
                      subtitle: 'チップ受け取り口座を確認する。',
                      trailing: OutlinedButton(
                        onPressed: (_tenantId == null || _openingConnectPortal)
                            ? null
                            : _openConnectPortal,
                        child: _openingConnectPortal
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('開く'),
                      ),
                    ),
                    if (_tenantId == null)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text(
                          '※ 店舗が未選択のためボタンを無効化しています。',
                          style: TextStyle(color: Colors.black54, fontSize: 12),
                        ),
                      ),
                  ],
                ),
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

class _StripeRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget trailing;
  const _StripeRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(10),
          ),
          padding: const EdgeInsets.all(8),
          child: Icon(icon, color: Colors.white, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: const TextStyle(color: Colors.black54, fontSize: 12),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        trailing,
      ],
    );
  }
}
