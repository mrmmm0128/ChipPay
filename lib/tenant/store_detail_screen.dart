import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:yourpay/tenant/newTenant/onboardingSheet.dart';
import 'package:yourpay/tenant/store_detail/drawer.dart';
import 'package:yourpay/tenant/store_detail/tabs/srore_home_tab.dart';
import 'package:yourpay/tenant/store_detail/tabs/store_qr_tab.dart';
import 'package:yourpay/tenant/store_detail/tabs/store_setting_tab.dart';
import 'package:yourpay/tenant/store_detail/tabs/store_staff_tab.dart';
import 'package:yourpay/tenant/newTenant/tenant_switch_bar.dart';

class StoreDetailScreen extends StatefulWidget {
  const StoreDetailScreen({super.key});
  @override
  State<StoreDetailScreen> createState() => _StoreDetailSScreenState();
}

class _StoreDetailSScreenState extends State<StoreDetailScreen> {
  // ---- state ----
  final amountCtrl = TextEditingController(text: '1000');
  final _functions = FirebaseFunctions.instanceFor(region: 'us-central1');

  bool loading = false;
  int _currentIndex = 0;

  String? tenantId;
  String? tenantName;

  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _empNameCtrl = TextEditingController();
  final _empEmailCtrl = TextEditingController();

  bool _argsApplied = false; // ルート引数適用済みフラグ
  bool _tenantInitialized = false; // 初回テナント確定済み

  // ---- theme (白黒) ----
  ThemeData _bwTheme(BuildContext context) {
    final base = Theme.of(context);
    OutlineInputBorder border(Color c) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: c),
    );
    return base.copyWith(
      colorScheme: base.colorScheme.copyWith(
        primary: Colors.black,
        secondary: Colors.black,
        onPrimary: Colors.white,
        onSecondary: Colors.white,
        surface: Colors.white,
        onSurface: Colors.black87,
      ),
      dialogBackgroundColor: Colors.white,
      scaffoldBackgroundColor: Colors.white,
      canvasColor: Colors.white,
      textTheme: base.textTheme.apply(
        bodyColor: Colors.black87,
        displayColor: Colors.black87,
      ),
      inputDecorationTheme: InputDecorationTheme(
        labelStyle: const TextStyle(color: Colors.black87),
        hintStyle: const TextStyle(color: Colors.black54),
        filled: true,
        fillColor: Colors.white,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        border: border(Colors.black12),
        enabledBorder: border(Colors.black12),
        focusedBorder: border(Colors.black),
      ),
    );
  }

  // ---- 店舗作成ダイアログ ----
  Future<void> createTenantDialog() async {
    final nameCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => Theme(
        data: _bwTheme(context),
        child: AlertDialog(
          title: const Text(
            '新しい店舗を作成',
            style: TextStyle(fontFamily: 'LINEseed'),
          ),
          content: TextField(
            controller: nameCtrl,
            decoration: const InputDecoration(
              labelText: '店舗名',
              hintText: '例）渋谷店',
            ),
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text(
                'キャンセル',
                style: TextStyle(fontFamily: 'LINEseed'),
              ),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('作成', style: TextStyle(fontFamily: 'LINEseed')),
            ),
          ],
        ),
      ),
    );

    if (ok == true) {
      final name = nameCtrl.text.trim();
      if (name.isEmpty) return;

      final u = FirebaseAuth.instance.currentUser;
      if (u == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('ログインが必要です')));
        return;
      }

      try {
        final ref = FirebaseFirestore.instance.collection(u.uid).doc();
        await ref.set({
          'name': name,
          'members': [u.uid],
          'memberUids': [u.uid],
          'status': 'active',
          'createdAt': FieldValue.serverTimestamp(),
          'createdBy': {'uid': u.uid, 'email': u.email},
          'subscription': {'status': 'inactive', 'plan': 'A'},
        });

        if (!mounted) return;
        setState(() {
          tenantId = ref.id;
          tenantName = name;
          _tenantInitialized = true;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Colors.white,
            content: Text(
              '店舗を作成しました',
              style: TextStyle(color: Colors.black87, fontFamily: 'LINEseed'),
            ),
          ),
        );

        await startOnboarding(ref.id, name);
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.white,
            content: Text(
              '作成に失敗: $e',
              style: const TextStyle(
                color: Colors.black87,
                fontFamily: 'LINEseed',
              ),
            ),
          ),
        );
      }
    }
  }

  // ---- オンボーディング ----
  Future<void> startOnboarding(String tenantId, String tenantName) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetCtx) {
        return Theme(
          data: _bwTheme(context),
          child: OnboardingSheet(
            tenantId: tenantId,
            tenantName: tenantName,
            functions: _functions,
          ),
        );
      },
    );
  }

  // ---- ルート引数適用（auth 確定前でも null 安全に）----
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_argsApplied) return;
    _argsApplied = true;

    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is Map) {
      final id = args['tenantId'] as String?;
      final nameArg = args['tenantName'] as String?;
      if (id != null) {
        setState(() {
          tenantId = id;
          tenantName = nameArg;
        });
      }
    }
  }

  // ---- 初回テナント推定（ルート→claims→Firestore）----
  Future<Map<String, String?>?> _resolveInitialTenant(User user) async {
    // 1) ルートで既に決まっていればそれを使う
    if (tenantId != null) {
      return {'id': tenantId, 'name': tenantName};
    }

    // 2) claims に tenantId があれば優先
    try {
      final token = await user.getIdTokenResult(true);
      final idFromClaims = token.claims?['tenantId'] as String?;
      if (idFromClaims != null) {
        String? name;
        try {
          final doc = await FirebaseFirestore.instance
              .collection(user.uid)
              .doc(idFromClaims)
              .get();
          if (doc.exists) {
            name = (doc.data()?['name'] as String?);
          }
        } catch (_) {}
        return {'id': idFromClaims, 'name': name};
      }
    } catch (_) {}

    // 3) 所属 or 作成済みの最初の店舗を拾う（なければ null）
    try {
      final col = FirebaseFirestore.instance.collection(user.uid);
      final qs1 = await col
          .where('memberUids', arrayContains: user.uid)
          .limit(1)
          .get();
      if (qs1.docs.isNotEmpty) {
        final d = qs1.docs.first;
        return {'id': d.id, 'name': (d.data()['name'] as String?)};
      }
      final qs2 = await col
          .where('createdBy.uid', isEqualTo: user.uid)
          .limit(1)
          .get();
      if (qs2.docs.isNotEmpty) {
        final d = qs2.docs.first;
        return {'id': d.id, 'name': (d.data()['name'] as String?)};
      }
    } catch (_) {}

    // 見つからない場合
    return null;
  }

  // ---- テナント切替 ----
  Future<void> _handleChangeTenant(String userUid, String id) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection(userUid)
          .doc(id)
          .get();
      final name = (doc.data()?['name'] as String?) ?? '店舗';
      if (!mounted) return;
      setState(() {
        tenantId = id;
        tenantName = name;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('切替に失敗: $e')));
    }
  }

  // ---- Drawer フォールバック ----
  Future<List<TenantOption>> _loadTenantOptionsFallback(String userUid) async {
    final col = FirebaseFirestore.instance.collection(userUid);
    final seen = <String>{};
    final out = <TenantOption>[];

    Future<void> addFrom(Query<Map<String, dynamic>> q) async {
      final qs = await q.get();
      for (final d in qs.docs) {
        if (seen.add(d.id)) {
          final data = d.data();
          final name = (data['name'] as String?)?.trim();
          out.add(
            TenantOption(
              id: d.id,
              name: (name?.isNotEmpty ?? false) ? name! : '店舗',
            ),
          );
        }
      }
    }

    await addFrom(col.where('memberUids', arrayContains: userUid));
    await addFrom(col.where('createdBy.uid', isEqualTo: userUid));

    if (tenantId != null && !out.any((e) => e.id == tenantId)) {
      out.add(TenantOption(id: tenantId!, name: (tenantName ?? '店舗')));
    }
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  @override
  void dispose() {
    amountCtrl.dispose();
    _empNameCtrl.dispose();
    _empEmailCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isNarrow = size.width < 480;
    final maxSwitcherW = (size.width * 0.7).clamp(280.0, 560.0);

    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, authSnap) {
        // 認証未確定（初期化中）
        if (authSnap.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final user = authSnap.data;
        final signedIn = user != null;

        // 未ログイン
        if (!signedIn) {
          return const Scaffold(body: Center(child: Text('ログインが必要です')));
        }

        // 初回テナント確定
        return FutureBuilder<Map<String, String?>?>(
          future: _tenantInitialized
              ? Future.value({'id': tenantId, 'name': tenantName})
              : _resolveInitialTenant(user),
          builder: (context, tSnap) {
            if (tSnap.connectionState == ConnectionState.waiting) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }

            // 初回のみ state に反映
            if (!_tenantInitialized) {
              final resolved = tSnap.data;
              _tenantInitialized = true;
              if (resolved != null) {
                tenantId = resolved['id'];
                tenantName = resolved['name'];
              }
            }

            final hasTenant = tenantId != null;

            return Scaffold(
              backgroundColor: const Color(0xFFF7F7F7),
              key: _scaffoldKey,
              appBar: AppBar(
                backgroundColor: const Color(0xFFF7F7F7),
                foregroundColor: Colors.black87,
                automaticallyImplyLeading: false,
                elevation: 0,
                toolbarHeight: 60,
                titleSpacing: 16,
                title: const Text(
                  "Tipri",
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                    fontFamily: "LINESeed",
                  ),
                ),
                // ← ここはそのまま
                // ★差し替え：BuilderやGlobalKey不要。公式の DrawerButton がベスト
                leading: isNarrow ? const DrawerButton() : null,

                // actions... などはそのまま
                actions: [
                  if (!isNarrow)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: maxSwitcherW.toDouble(),
                        ),
                        child: TenantSwitcherBar(
                          currentTenantId: tenantId,
                          currentTenantName: tenantName,
                          onChanged: (id, name) {
                            setState(() {
                              tenantId = id;
                              tenantName = name;
                            });
                          },
                        ),
                      ),
                    ),
                  IconButton(
                    onPressed: () {},
                    icon: const Icon(Icons.notifications_outlined),
                  ),
                ],
                bottom: const PreferredSize(
                  preferredSize: Size.fromHeight(1),
                  child: SizedBox(
                    height: 1,
                    child: ColoredBox(color: Colors.black12),
                  ),
                ),
              ),

              // Drawer
              drawer: isNarrow
                  ? Drawer(
                      // ★追加：必ず Drawer でラップ
                      child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                        stream: FirebaseFirestore.instance
                            .collection(user.uid)
                            .where('memberUids', arrayContains: user.uid)
                            .snapshots(),
                        builder: (context, snap) {
                          List<TenantOption> options = [];
                          if (snap.hasData) {
                            options = snap.data!.docs.map((d) {
                              final data = d.data();
                              final name = (data['name'] as String?)?.trim();
                              return TenantOption(
                                id: d.id,
                                name: (name?.isNotEmpty ?? false)
                                    ? name!
                                    : '店舗',
                              );
                            }).toList();
                          }
                          if (tenantId != null &&
                              !options.any((e) => e.id == tenantId)) {
                            options = [
                              ...options,
                              TenantOption(
                                id: tenantId!,
                                name: tenantName ?? '店舗',
                              ),
                            ];
                          }

                          if (options.isEmpty) {
                            return FutureBuilder<List<TenantOption>>(
                              future: _loadTenantOptionsFallback(user.uid),
                              builder: (context, fb) {
                                final opts = fb.data ?? const <TenantOption>[];
                                return AppDrawer(
                                  tenantName: tenantName,
                                  currentTenantId: tenantId,
                                  currentIndex: _currentIndex,
                                  onTapIndex: (i) =>
                                      setState(() => _currentIndex = i),
                                  tenantOptions: opts,
                                  onChangeTenant: (id) async =>
                                      _handleChangeTenant(user.uid, id),
                                  onCreateTenant: () async =>
                                      createTenantDialog(),
                                );
                              },
                            );
                          }

                          return AppDrawer(
                            tenantName: tenantName,
                            currentTenantId: tenantId,
                            currentIndex: _currentIndex,
                            onTapIndex: (i) =>
                                setState(() => _currentIndex = i),
                            tenantOptions: options,
                            onChangeTenant: (id) async =>
                                _handleChangeTenant(user.uid, id),
                            onCreateTenant: () async => createTenantDialog(),
                          );
                        },
                      ),
                    )
                  : null,

              body: hasTenant
                  ? Column(
                      children: [
                        Expanded(
                          child: IndexedStack(
                            index: _currentIndex,
                            children: [
                              // ここは hasTenant=true の分岐内なので `!` は安全
                              StoreHomeTab(
                                tenantId: tenantId!,
                                tenantName: tenantName,
                              ),
                              StoreQrTab(
                                tenantId: tenantId!,
                                tenantName: tenantName,
                              ),
                              StoreStaffTab(tenantId: tenantId!),
                              StoreSettingsTab(tenantId: tenantId!),
                            ],
                          ),
                        ),
                      ],
                    )
                  : Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('店舗が見つかりませんでした'),
                          const SizedBox(height: 12),
                          FilledButton(
                            onPressed: createTenantDialog,
                            child: const Text('店舗を作成する'),
                          ),
                        ],
                      ),
                    ),

              bottomNavigationBar: BottomNavigationBar(
                type: BottomNavigationBarType.fixed,
                backgroundColor: Colors.white,
                selectedItemColor: Colors.black,
                unselectedItemColor: Colors.black54,
                currentIndex: _currentIndex,
                onTap: (i) => setState(() => _currentIndex = i),
                items: const [
                  BottomNavigationBarItem(icon: Icon(Icons.home), label: 'ホーム'),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.qr_code_2),
                    label: '印刷',
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.group),
                    label: 'スタッフ',
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.settings),
                    label: '設定',
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
