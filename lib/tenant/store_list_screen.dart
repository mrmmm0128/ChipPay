import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:yourpay/tenant/store_list/store_card.dart';

class StoreListScreen extends StatefulWidget {
  const StoreListScreen({super.key});
  @override
  State<StoreListScreen> createState() => _StoreListScreenState();
}

class _StoreListScreenState extends State<StoreListScreen> {
  final _nameCtrl = TextEditingController();
  bool _creating = false;
  String? _justCreatedId; // 直近に作成したテナントをハイライト
  final _functions = FirebaseFunctions.instanceFor(region: 'us-central1');
  final uid = FirebaseAuth.instance.currentUser?.uid;
  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _createTenant() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('店舗名を入力してください')));
      return;
    }
    setState(() => _creating = true);
    try {
      final user = FirebaseAuth.instance.currentUser!;
      final ref = FirebaseFirestore.instance.collection(uid!).doc(); // 自動ID
      await ref.set({
        'name': name,
        'status': 'active',
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        'memberUids': [user.uid], // 自分をメンバーに追加
        // 追加: だれが作ったかわかるように
        'createdBy': {
          'uid': user.uid,
          'email': user.email,
          'displayName': user.displayName,
        },
      });

      if (!mounted) return;
      setState(() => _justCreatedId = ref.id); // ハイライト用に保持
      Navigator.of(context).pop(); // ダイアログを閉じる
      _nameCtrl.clear();

      // 遷移しない（一覧にカードが追加表示される）
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('店舗を作成しました')));
      await _createConnectAndMaybeOnboard(ref.id);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('作成に失敗: $e')));
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _createConnectAndMaybeOnboard(String tenantId) async {
    // 1) ぐるぐる表示（await しない！）
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => WillPopScope(
        onWillPop: () async => false,
        child: const Dialog(
          child: Padding(
            padding: EdgeInsets.all(20),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(width: 16),
                Flexible(child: Text('Stripe接続の準備中…')),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      // 2) Connect アカウント作成
      await _functions.httpsCallable('createConnectAccountForTenant').call({
        'tenantId': tenantId,
      });
    } on FirebaseFunctionsException catch (e) {
      // 失敗時も必ず閉じる
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop(); // ぐるぐる閉じる
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Stripe接続の準備に失敗: ${e.code} ${e.message ?? ''}'),
          ),
        );
      }
      return;
    } catch (e) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Stripe接続の準備に失敗: $e')));
      }
      return;
    }

    // 3) 成功したので ぐるぐるを閉じる
    if (mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    } else {
      return;
    }

    // 4) 今すぐオンボーディングするか確認
    final go = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Stripeに接続しますか？'),
        content: const Text('決済を受け付けるにはStripeアカウントのオンボーディングが必要です。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('あとで'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('今すぐ接続'),
          ),
        ],
      ),
    );

    if (go == true) {
      try {
        final res = await _functions
            .httpsCallable('createAccountOnboardingLink')
            .call({'tenantId': tenantId});
        final url = (res.data as Map)['url'] as String;
        await launchUrlString(url, mode: LaunchMode.externalApplication);
      } on FirebaseFunctionsException catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('オンボーディング開始に失敗: ${e.code} ${e.message ?? ''}'),
          ),
        );
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('オンボーディング開始に失敗: $e')));
      }
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('後から「Stripeに接続」ボタンから再開できます')),
      );
    }
  }

  void _openCreateDialog() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('新しい店舗を作成'),
        content: TextField(
          controller: _nameCtrl,
          decoration: const InputDecoration(labelText: '店舗名'),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: _creating ? null : _createTenant,
            child: _creating
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('作成'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      Future.microtask(() => Navigator.pushReplacementNamed(context, '/login'));
      return const SizedBox.shrink();
    }

    final stream = FirebaseFirestore.instance
        .collection(uid)
        .where('memberUids', arrayContains: uid)
        .snapshots();

    // 黒ベースのボタン（空状態用）
    final primaryBtnStyle = FilledButton.styleFrom(
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    );

    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7), // やわらかい薄グレー
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        automaticallyImplyLeading: false,
        elevation: 0,
        title: const Text(
          '店舗を選択',
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
        ),
        actions: [
          // ← 追加：アカウント
          IconButton(
            icon: const Icon(Icons.account_circle_outlined),
            tooltip: 'アカウント',
            onPressed: () => Navigator.pushNamed(context, '/account'),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await FirebaseAuth.instance.signOut();
              if (!mounted) return;
              Navigator.pushReplacementNamed(context, '/login');
            },
            tooltip: 'Sign out',
          ),
          const SizedBox(width: 4),
        ],
      ),

      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openCreateDialog,
        icon: const Icon(Icons.add_business),
        label: const Text('新しい店舗'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: stream,
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text('読み込みエラー: ${snap.error}'),
              ),
            );
          }
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final docs = [...(snap.data?.docs ?? [])];
          docs.sort((a, b) {
            final ta = (a['createdAt'] as Timestamp?);
            final tb = (b['createdAt'] as Timestamp?);
            if (tb == null && ta == null) return 0;
            if (tb == null) return -1;
            if (ta == null) return 1;
            return tb.compareTo(ta);
          });

          if (docs.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('まだ店舗がありません'),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    style: primaryBtnStyle,
                    onPressed: _openCreateDialog,
                    icon: const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: Icon(Icons.add),
                    ),
                    label: const Text('最初の店舗を作成'),
                  ),
                ],
              ),
            );
          }

          return LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth >= 720;
              if (isWide) {
                return GridView.builder(
                  padding: const EdgeInsets.all(16),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: 16,
                    crossAxisSpacing: 16,
                    childAspectRatio: 3.0,
                  ),
                  itemCount: docs.length,
                  itemBuilder: (_, i) {
                    final d = docs[i].data() as Map<String, dynamic>;
                    final id = docs[i].id;
                    return StoreCard(
                      id: id,
                      name: d['name'] ?? '(no name)',
                      status: d['status'] ?? 'unknown',
                      creator: (d['createdBy']?['email'] as String?) ?? '',
                      isNew: id == _justCreatedId,
                      onTap: () => Navigator.pushNamed(
                        context,
                        '/store',
                        arguments: {'tenantId': id, 'tenantName': d['name']},
                      ),
                    );
                  },
                );
              } else {
                return ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: docs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 16),
                  itemBuilder: (_, i) {
                    final d = docs[i].data() as Map<String, dynamic>;
                    final id = docs[i].id;
                    return StoreCard(
                      id: id,
                      name: d['name'] ?? '(no name)',
                      status: d['status'] ?? 'unknown',
                      creator: (d['createdBy']?['email'] as String?) ?? '',
                      isNew: id == _justCreatedId,
                      onTap: () => Navigator.pushNamed(
                        context,
                        '/store',
                        arguments: {'tenantId': id, 'tenantName': d['name']},
                      ),
                    );
                  },
                );
              }
            },
          );
        },
      ),
    );
  }
}
