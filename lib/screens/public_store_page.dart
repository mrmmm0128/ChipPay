import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class PublicStorePage extends StatefulWidget {
  const PublicStorePage({super.key});

  @override
  State<PublicStorePage> createState() => _PublicStorePageState();
}

class _PublicStorePageState extends State<PublicStorePage> {
  String? tenantId;
  String? tenantName;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loadFromRouteOrQuery();
  }

  Future<void> _loadFromRouteOrQuery() async {
    // 1) Navigator 引数
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is Map && args['tenantId'] is String) {
      tenantId = args['tenantId'] as String;
      tenantName = args['tenantName'] as String?;
    }

    // 2) URL クエリ（パス方式: /p?t=...）
    tenantId ??= Uri.base.queryParameters['t'];

    // 3) URL フラグメント（ハッシュ方式: #/p?t=...）
    if (tenantId == null && Uri.base.fragment.isNotEmpty) {
      final frag = Uri.base.fragment.startsWith('/')
          ? Uri.base.fragment.substring(1) // "/p?t=..." → "p?t=..."
          : Uri.base.fragment;
      final fUri = Uri.parse(frag); // path: "p", query: "t=..."
      tenantId = fUri.queryParameters['t'];
    }

    if (tenantId != null && tenantName == null) {
      final doc = await FirebaseFirestore.instance
          .collection('tenants')
          .doc(tenantId)
          .get();
      if (doc.exists) {
        setState(() => tenantName = (doc.data()!['name'] as String?) ?? '店舗');
        return;
      }
    }
    setState(() {}); // 再描画
  }

  @override
  Widget build(BuildContext context) {
    if (tenantId == null) {
      return const Scaffold(
        body: Center(child: Text('店舗が見つかりません（URLをご確認ください）')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(tenantName ?? '店舗'),
        automaticallyImplyLeading: false,
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('tenants')
            .doc(tenantId)
            .collection('employees')
            .orderBy('createdAt', descending: true)
            .snapshots(),
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: Text('読み込みエラー: ${snap.error}'));
          }
          if (!snap.hasData)
            return const Center(child: CircularProgressIndicator());

          final docs = snap.data!.docs;
          if (docs.isEmpty) {
            return const Center(child: Text('スタッフ情報はまだありません'));
          }

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
                    childAspectRatio: 3.5,
                  ),
                  itemCount: docs.length,
                  itemBuilder: (_, i) {
                    // GridView.builder / ListView.separated 内
                    final id = docs[i].id;
                    final d = docs[i].data() as Map<String, dynamic>;
                    return _EmployeePublicCard(
                      name: d['name'] ?? '',
                      email: d['email'] ?? '',
                      photoUrl: d['photoUrl'] ?? '',
                      onTap: () {
                        Navigator.pushNamed(
                          context,
                          '/staff',
                          arguments: {
                            'tenantId': tenantId,
                            'employeeId': id,
                            'name': d['name'],
                            'email': d['email'],
                            'photoUrl': d['photoUrl'],
                          },
                        );
                      },
                    );
                  },
                );
              } else {
                return ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: docs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (_, i) {
                    // GridView.builder / ListView.separated 内
                    final id = docs[i].id;
                    final d = docs[i].data() as Map<String, dynamic>;
                    return _EmployeePublicCard(
                      name: d['name'] ?? '',
                      email: d['email'] ?? '',
                      photoUrl: d['photoUrl'] ?? '',
                      onTap: () {
                        Navigator.pushNamed(
                          context,
                          '/staff',
                          arguments: {
                            'tenantId': tenantId,
                            "tenantName": tenantName,
                            'employeeId': id,
                            'name': d['name'],
                            'email': d['email'],
                            'photoUrl': d['photoUrl'],
                          },
                        );
                      },
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

class _EmployeePublicCard extends StatelessWidget {
  final String name;
  final String email;
  final String photoUrl;
  final VoidCallback? onTap;

  const _EmployeePublicCard({
    required this.name,
    required this.email,
    required this.photoUrl,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 6,
      shadowColor: Colors.black26,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              CircleAvatar(
                radius: 26,
                backgroundImage: (photoUrl.isNotEmpty)
                    ? NetworkImage(photoUrl)
                    : null,
                child: (photoUrl.isEmpty) ? const Icon(Icons.person) : null,
              ),
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
                    const SizedBox(height: 2),
                    Text(email, style: Theme.of(context).textTheme.bodySmall),
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
