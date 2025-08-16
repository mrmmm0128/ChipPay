import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class StoreListScreen extends StatefulWidget {
  const StoreListScreen({super.key});
  @override
  State<StoreListScreen> createState() => _StoreListScreenState();
}

class _StoreListScreenState extends State<StoreListScreen> {
  final _nameCtrl = TextEditingController();
  bool _creating = false;
  String? _justCreatedId; // 直近に作成したテナントをハイライト

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
      final ref = FirebaseFirestore.instance
          .collection('tenants')
          .doc(); // 自動ID
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
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('作成に失敗: $e')));
    } finally {
      if (mounted) setState(() => _creating = false);
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

    // 複合インデックス不要のため orderBy は外し、クライアント側で並び替えます
    final stream = FirebaseFirestore.instance
        .collection('tenants')
        .where('memberUids', arrayContains: uid)
        .snapshots();

    return Scaffold(
      appBar: AppBar(
        title: const Text('店舗を選択'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await FirebaseAuth.instance.signOut();
              if (!mounted) return;
              Navigator.pushReplacementNamed(context, '/login');
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openCreateDialog,
        icon: const Icon(Icons.add_business),
        label: const Text('新しい店舗'),
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

          // docs を createdAt 降順でクライアントソート
          final docs = [...(snap.data?.docs ?? [])];
          docs.sort((a, b) {
            final ta = (a['createdAt'] as Timestamp?);
            final tb = (b['createdAt'] as Timestamp?);
            if (tb == null && ta == null) return 0;
            if (tb == null) return -1;
            if (ta == null) return 1;
            return tb.compareTo(ta); // 降順
          });

          if (docs.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('まだ店舗がありません'),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _openCreateDialog,
                    icon: const Icon(Icons.add),
                    label: const Text('最初の店舗を作成'),
                  ),
                ],
              ),
            );
          }

          // 画面幅に応じてカードを並べる（広い画面は2列、狭い画面は1列）
          return LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth >= 720;
              if (isWide) {
                return GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 3.0,
                  ),
                  itemCount: docs.length,
                  itemBuilder: (_, i) {
                    final d = docs[i].data() as Map<String, dynamic>;
                    final id = docs[i].id;
                    return _StoreCard(
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
                  padding: const EdgeInsets.all(12),
                  itemCount: docs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (_, i) {
                    final d = docs[i].data() as Map<String, dynamic>;
                    final id = docs[i].id;
                    return _StoreCard(
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

class _StoreCard extends StatelessWidget {
  final String id;
  final String name;
  final String status;
  final String creator; // 追加: 作成者のメールなど
  final bool isNew;
  final VoidCallback onTap;

  const _StoreCard({
    required this.id,
    required this.name,
    required this.status,
    required this.creator,
    required this.isNew,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final captionStyle = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: Colors.white70);
    return Card(
      elevation: 6,
      shadowColor: Colors.black26,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              const Icon(Icons.storefront, size: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text('ID: $id  •  $status', style: captionStyle),
                    if (creator.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text('作成: $creator', style: captionStyle),
                    ],
                  ],
                ),
              ),
              if (isNew)
                const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: Chip(label: Text('NEW')),
                ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}
