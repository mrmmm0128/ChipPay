import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

class PublicStorePage extends StatefulWidget {
  const PublicStorePage({super.key});

  @override
  State<PublicStorePage> createState() => _PublicStorePageState();
}

class _PublicStorePageState extends State<PublicStorePage> {
  String? tenantId;
  String? tenantName;

  // ▼ 追加：名前フィルタ
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() {
      setState(() => _query = _searchCtrl.text.trim().toLowerCase());
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

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

    // 2) URL クエリ（/p?t=...）
    tenantId ??= Uri.base.queryParameters['t'];

    // 3) ハッシュ（#/p?t=...）
    if (tenantId == null && Uri.base.fragment.isNotEmpty) {
      final frag = Uri.base.fragment.startsWith('/')
          ? Uri.base.fragment.substring(1)
          : Uri.base.fragment;
      final fUri = Uri.parse(frag);
      tenantId = fUri.queryParameters['t'];
    }

    if (tenantId != null && tenantName == null) {
      final doc = await FirebaseFirestore.instance
          .collection('tenants')
          .doc(tenantId)
          .get();
      if (doc.exists) {
        tenantName = (doc.data()!['name'] as String?) ?? '店舗';
      }
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (tenantId == null) {
      return const Scaffold(
        body: Center(child: Text('店舗が見つかりません（URLをご確認ください）')),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 0,
        title: Text(
          tenantName ?? '店舗',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        automaticallyImplyLeading: false,
      ),
      body: Column(
        children: [
          // ▼ 名前で絞り込み（白×黒のネイティブ風）
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: '名前で検索',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchCtrl.clear();
                          FocusScope.of(context).unfocus();
                        },
                      ),
                filled: true,
                fillColor: Colors.white,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Colors.black12),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Colors.black12),
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),

          // ▼ スタッフ一覧（順位はグリッド順 = 表示順で付与）
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
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
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                // 取得 → フィルタ（クライアント側）
                final all = snap.data!.docs;
                final filtered = all.where((doc) {
                  final d = doc.data() as Map<String, dynamic>;
                  final name = (d['name'] ?? '').toString().toLowerCase();
                  return _query.isEmpty || name.contains(_query);
                }).toList();

                if (filtered.isEmpty) {
                  return const Center(child: Text('該当するスタッフがいません'));
                }

                return LayoutBuilder(
                  builder: (context, constraints) {
                    // レスポンシブ列数
                    final w = constraints.maxWidth;
                    int cross = 2;
                    if (w >= 1100) {
                      cross = 5;
                    } else if (w >= 900) {
                      cross = 4;
                    } else if (w >= 680) {
                      cross = 3;
                    }

                    return GridView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      physics: const BouncingScrollPhysics(),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: cross,
                        mainAxisSpacing: 16,
                        crossAxisSpacing: 16,
                        childAspectRatio: 0.80, // ← 0.92 から少し縦長にして余白を確保
                      ),
                      itemCount: filtered.length,
                      itemBuilder: (_, i) {
                        final doc = filtered[i];
                        final data = doc.data() as Map<String, dynamic>;
                        final id = doc.id;
                        final name = (data['name'] ?? '') as String;
                        final email = (data['email'] ?? '') as String;
                        final photoUrl = (data['photoUrl'] ?? '') as String;

                        return _EmployeePublicTile(
                          rank: i + 1,
                          name: name,
                          email: email,
                          photoUrl: photoUrl,
                          onTap: () {
                            Navigator.pushNamed(
                              context,
                              '/staff',
                              arguments: {
                                'tenantId': tenantId,
                                'tenantName': tenantName,
                                'employeeId': id,
                                'name': name,
                                'email': email,
                                'photoUrl': photoUrl,
                              },
                            );
                          },
                        );
                      },
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _EmployeePublicTile extends StatelessWidget {
  final int rank;
  final String name;
  final String email;
  final String photoUrl;
  final VoidCallback? onTap;

  const _EmployeePublicTile({
    required this.rank,
    required this.name,
    required this.email,
    required this.photoUrl,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // 上位は少しだけ強調（色は黒/白のまま）
    final isTop3 = rank <= 3;

    return Material(
      color: Colors.white,
      elevation: 6,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              // 丸写真＋左上に“丸”の順位バッジ（写真にかぶせる）
              Stack(
                clipBehavior: Clip.none,
                children: [
                  CircleAvatar(
                    radius: 44, // ちょい大きめで写真映え
                    backgroundImage: (photoUrl.isNotEmpty)
                        ? NetworkImage(photoUrl)
                        : null,
                    child: (photoUrl.isEmpty)
                        ? const Icon(Icons.person, size: 40)
                        : null,
                  ),
                  Positioned(
                    top: -6,
                    left: -6,
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: Colors.black,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Colors.white,
                          width: 2,
                        ), // 縁取りで視認性UP
                        boxShadow: const [
                          BoxShadow(
                            blurRadius: 4,
                            color: Colors.black26,
                            offset: Offset(0, 2),
                          ),
                        ],
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        '$rank',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 12),

              // 名前（中央寄せ・太字）— 上位3は少しだけ強調
              Text(
                name.isEmpty ? 'スタッフ' : name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontWeight: isTop3 ? FontWeight.w800 : FontWeight.w700,
                ),
              ),

              // メール（任意表示・白黒基調の補助テキスト）
              if (email.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  email,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: Colors.black54),
                ),
              ],

              const Spacer(),

              // 右下のチートシンボル（ナビの示唆、黒の不透明度で控えめに）
              Align(
                alignment: Alignment.bottomRight,
                child: Icon(
                  Icons.chevron_right,
                  color: Colors.black.withOpacity(0.45),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
