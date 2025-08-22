import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({super.key});
  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen>
    with SingleTickerProviderStateMixin {
  bool _checking = true;
  bool _isAdmin = false;
  late final TabController _tab;

  // 店舗検索
  final _tenantSearch = TextEditingController();
  String _tenantQuery = '';

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this); // ← 2タブ
    _tenantSearch.addListener(() {
      setState(() => _tenantQuery = _tenantSearch.text.trim().toLowerCase());
    });
    _checkAdmin();
  }

  @override
  void dispose() {
    _tenantSearch.dispose();
    _tab.dispose();
    super.dispose();
  }

  Future<void> _checkAdmin() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (!mounted) return;
      Navigator.pushReplacementNamed(context, '/admin-login');
      return;
    }
    final token = await user.getIdTokenResult(true);
    final claims = token.claims ?? {};
    var ok = (claims['isAdmin'] == true) || (claims['role'] == 'admin');
    if (!ok) {
      final snap = await FirebaseFirestore.instance
          .collection('admins')
          .doc(user.uid)
          .get();
      if (snap.exists) ok = (snap.data()!['active'] as bool?) ?? true;
    }
    if (!mounted) return;
    setState(() {
      _checking = false;
      _isAdmin = ok;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!_isAdmin) {
      return Scaffold(
        appBar: _appBar(const Text('権限エラー')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('管理者権限がありません。'),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () async {
                  await FirebaseAuth.instance.signOut();
                  if (!mounted) return;
                  Navigator.pushReplacementNamed(context, '/admin-login');
                },
                child: const Text('ログイン画面へ'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),
      appBar: _appBar(
        const Text('運営ダッシュボード'),
        bottom: TabBar(
          controller: _tab,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.black87,
          indicator: const BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.all(Radius.circular(10)),
          ),
          dividerColor: Colors.transparent,
          tabs: const [
            Tab(text: 'ホーム', icon: Icon(Icons.dashboard_outlined)),
            Tab(text: '店舗一覧', icon: Icon(Icons.store_mall_directory_outlined)),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          const _AdminHomeTab(), // ← ホーム（統計）
          _AdminStoresTab(
            // ← 店舗一覧
            query: _tenantQuery,
            controller: _tenantSearch,
          ),
        ],
      ),
    );
  }

  AppBar _appBar(Widget title, {PreferredSizeWidget? bottom}) {
    return AppBar(
      backgroundColor: Colors.white,
      foregroundColor: Colors.black,
      automaticallyImplyLeading: false,
      elevation: 0,
      title: DefaultTextStyle.merge(
        style: const TextStyle(fontWeight: FontWeight.w600),
        child: title,
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.logout),
          tooltip: 'Sign out',
          onPressed: () async {
            await FirebaseAuth.instance.signOut();
            if (!mounted) return;
            Navigator.pushReplacementNamed(context, '/admin-login');
          },
        ),
        const SizedBox(width: 4),
      ],
      bottom: bottom,
    );
  }
}

// ---------- タブ: ホーム（登録状況などの概要） ----------
class _AdminHomeTab extends StatelessWidget {
  const _AdminHomeTab();

  Future<int> _count(Query q) async => (await q.count().get()).count!;

  @override
  Widget build(BuildContext context) {
    final tenantsQ = FirebaseFirestore.instance.collection('tenants');
    final staffQ = FirebaseFirestore.instance.collectionGroup('employees');
    final tipsQ = FirebaseFirestore.instance.collectionGroup('tips');
    final activeQ = tenantsQ.where('status', isEqualTo: 'active');
    final suspendedQ = tenantsQ.where('status', isEqualTo: 'suspended');

    // ★ コントラスト用に色を固定
    const cardBg = Colors.white;
    const textMain = Colors.black87;
    const textSub = Colors.black54;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  _metric('店舗数', _count(tenantsQ), cardBg, textMain, textSub),
                  _metric('稼働中', _count(activeQ), cardBg, textMain, textSub),
                  _metric('停止中', _count(suspendedQ), cardBg, textMain, textSub),
                  _metric('スタッフ数', _count(staffQ), cardBg, textMain, textSub),
                  _metric('決済(件)', _count(tipsQ), cardBg, textMain, textSub),
                ],
              ),
              const SizedBox(height: 16),

              // ヒントカードも白＋黒
              Card(
                color: cardBg,
                elevation: 4,
                shadowColor: Colors.black26,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const ListTile(
                  title: Text(
                    'ヒント',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: textMain,
                    ),
                  ),
                  subtitle: Text(
                    '店舗停止は各店舗詳細から行えます。',
                    style: TextStyle(color: textSub),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ← 引数に色を渡す版に変更
  Widget _metric(
    String title,
    Future<int> f,
    Color cardBg,
    Color textMain,
    Color textSub,
  ) {
    return SizedBox(
      width: 220,
      child: Card(
        color: cardBg, // ★白固定
        elevation: 4,
        shadowColor: Colors.black26,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FutureBuilder<int>(
            future: f,
            builder: (context, snap) {
              final value = snap.hasData ? '${snap.data}' : '...';
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(color: textSub)),
                  const SizedBox(height: 6),
                  Text(
                    value,
                    style: TextStyle(
                      color: textMain, // ★黒固定
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

// ---------- タブ: 店舗一覧 ----------
class _AdminStoresTab extends StatelessWidget {
  final String query;
  final TextEditingController controller;
  const _AdminStoresTab({required this.query, required this.controller});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // 検索
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
          child: TextField(
            controller: controller,
            decoration: InputDecoration(
              hintText: '店舗名で検索',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () => controller.clear(),
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
        const SizedBox(height: 6),
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('tenants')
                .orderBy('createdAt', descending: true)
                .snapshots(),
            builder: (context, snap) {
              if (snap.hasError)
                return Center(child: Text('読み込みエラー: ${snap.error}'));
              if (!snap.hasData)
                return const Center(child: CircularProgressIndicator());

              final docs = snap.data!.docs.where((d) {
                final name = (d['name'] ?? '').toString().toLowerCase();
                return query.isEmpty || name.contains(query);
              }).toList();

              if (docs.isEmpty)
                return const Center(child: Text('該当する店舗がありません'));

              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                itemCount: docs.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (_, i) {
                  final d = docs[i].data() as Map<String, dynamic>;
                  final id = docs[i].id;
                  final status = (d['status'] ?? 'unknown').toString();

                  return Card(
                    elevation: 4,
                    shadowColor: Colors.black26,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: ListTile(
                      leading: const CircleAvatar(
                        backgroundColor: Colors.black,
                        foregroundColor: Colors.white,
                        child: Icon(Icons.storefront),
                      ),
                      title: Text(
                        d['name'] ?? '(no name)',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text('ID: $id  •  $status'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () {
                        Navigator.pushNamed(
                          context,
                          '/admin/tenant',
                          arguments: {'tenantId': id, 'tenantName': d['name']},
                        );
                      },
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
