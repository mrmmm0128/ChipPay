import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:yourpay/tenant/store_detail/drawer.dart';
import 'package:yourpay/tenant/store_detail/tabs/srore_home_tab.dart';
import 'package:yourpay/tenant/store_detail/tabs/store_qr_tab.dart';
import 'package:yourpay/tenant/store_detail/tabs/store_setting_tab.dart';
import 'package:yourpay/tenant/store_detail/tabs/store_staff_tab.dart';
import 'package:yourpay/tenant/tenant_switch_bar.dart';

class StoreDetailScreen extends StatefulWidget {
  const StoreDetailScreen({super.key});

  @override
  State<StoreDetailScreen> createState() => _StoreDetailSScreenState();
}

class _StoreDetailSScreenState extends State<StoreDetailScreen> {
  final amountCtrl = TextEditingController(text: '1000');
  final _functions = FirebaseFunctions.instanceFor(region: 'us-central1');
  String? checkoutUrl;
  String? sessionId;
  String? publicStoreUrl;
  bool loading = false;
  int _currentIndex = 0;

  String? tenantId;
  String? tenantName;
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  final _empNameCtrl = TextEditingController();
  final _empEmailCtrl = TextEditingController();

  bool _argsApplied = false;

  // ---- utils ----------------------------------------------------
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

  // ---- あなたの createTenantDialog をそのまま流用（必要最小限だけ補完） ----
  Future<void> createTenantDialog() async {
    final nameCtrl = TextEditingController();
    final _uid = FirebaseAuth.instance.currentUser!.uid;

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => Theme(
        data: _bwTheme(context),
        child: AlertDialog(
          title: const Text('新しい店舗を作成'),
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
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('作成'),
            ),
          ],
        ),
      ),
    );

    if (ok == true) {
      final name = nameCtrl.text.trim();
      if (name.isEmpty) return;

      try {
        final ref = FirebaseFirestore.instance.collection('tenants').doc();
        await ref.set({
          'name': name,
          'members': [_uid], // 旧互換
          'memberUids': [_uid], // これが Drawer のクエリで使われる
          'status': 'active',
          'createdAt': FieldValue.serverTimestamp(),
          'createdBy': {
            'uid': _uid,
            'email': FirebaseAuth.instance.currentUser?.email,
          },
          'subscription': {'status': 'inactive', 'plan': 'A'},
        });
        if (!mounted) return;

        setState(() {
          tenantId = ref.id;
          tenantName = name;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Colors.white,
            content: Text('店舗を作成しました', style: TextStyle(color: Colors.black87)),
          ),
        );

        // オンボーディングを使うならここで呼ぶ（任意）
        await startOnboarding(ref.id, name);
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.white,
            content: Text(
              '作成に失敗: $e',
              style: const TextStyle(color: Colors.black87),
            ),
          ),
        );
      }
    }
  }

  // ---------- オンボーディング（モーダル/ステッパー） ----------
  Future<void> startOnboarding(String tenantId, String tenantName) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetCtx) {
        // ★ 紫対策：ボトムシート全体を白黒テーマで包む
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

  // ---- 初期 tenant の適用 ------------------------------------------------
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _applyRouteArgsIfAny();
  }

  Future<void> _applyRouteArgsIfAny() async {
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
        if (nameArg == null) {
          final doc = await FirebaseFirestore.instance
              .collection('tenants')
              .doc(id)
              .get();
          if (doc.exists) {
            setState(
              () => tenantName = (doc.data()!['name'] as String?) ?? tenantName,
            );
          }
        }
      }
    }

    if (tenantId == null) {
      final user = FirebaseAuth.instance.currentUser!;
      final token = await user.getIdTokenResult(true);
      final idFromClaims = token.claims?['tenantId'] as String?;
      if (idFromClaims != null) {
        setState(() => tenantId = idFromClaims);
        final doc = await FirebaseFirestore.instance
            .collection('tenants')
            .doc(idFromClaims)
            .get();
        if (doc.exists) {
          setState(() => tenantName = doc.data()!['name'] as String?);
        }
      }
    }
  }

  // ---- 店舗切替（Drawerから呼ばれる） -----------------------------------
  Future<void> _handleChangeTenant(String id) async {
    final doc = await FirebaseFirestore.instance
        .collection('tenants')
        .doc(id)
        .get();
    final name = (doc.data()?['name'] as String?) ?? '店舗';
    if (!mounted) return;
    setState(() {
      tenantId = id;
      tenantName = name;
    });
  }

  // ---- Drawer: ストリームが空の時のフォールバック -------------------------
  Future<List<TenantOption>> _loadTenantOptionsFallback() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return [];
    final col = FirebaseFirestore.instance.collection('tenants');
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

    await addFrom(col.where('members', arrayContains: uid));
    await addFrom(col.where('createdBy.uid', isEqualTo: uid));

    // ここで「現在選択されている店舗」を union して必ず選択肢に含める
    if (tenantId != null && !out.any((e) => e.id == tenantId)) {
      out.add(TenantOption(id: tenantId!, name: (tenantName ?? '店舗')));
    }

    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  // ---- 決済（既存） ------------------------------------------------------
  Future<void> createSession() async {
    setState(() => loading = true);
    try {
      final callable = FirebaseFunctions.instance.httpsCallable(
        'createCheckoutSession',
      );
      final result = await callable.call({
        'amount': int.parse(amountCtrl.text),
        'memo': 'Walk-in',
      });
      setState(() {
        checkoutUrl = result.data['checkoutUrl'];
        sessionId = result.data['sessionId'];
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('エラー: $e')));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  void dispose() {
    amountCtrl.dispose();
    _empNameCtrl.dispose();
    _empEmailCtrl.dispose();
    super.dispose();
    // ignore: unused_field
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isNarrow = size.width < 480;
    final maxSwitcherW = (size.width * 0.7).clamp(280.0, 560.0);
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
        title: Text(
          "tipri",
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
        ),
        leading: isNarrow
            ? IconButton(
                icon: const Icon(Icons.menu, color: Colors.black87),
                onPressed: () => _scaffoldKey.currentState?.openDrawer(),
              )
            : null,
        actions: [
          if (!isNarrow)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxSwitcherW.toDouble()),
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
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(
            height: 1,
            color: Colors.black12, // 好みの色
          ),
        ),
      ),

      // Drawer：memberUids ストリーム → 空ならフォールバック、さらに現在選択を union
      drawer: isNarrow
          ? StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: FirebaseFirestore.instance
                  .collection('tenants')
                  .where(
                    'memberUids',
                    arrayContains: FirebaseAuth.instance.currentUser?.uid,
                  )
                  .snapshots(),
              builder: (context, snap) {
                List<TenantOption> options = [];
                if (snap.hasData) {
                  options = snap.data!.docs.map((d) {
                    final data = d.data();
                    final name = (data['name'] as String?)?.trim();
                    return TenantOption(
                      id: d.id,
                      name: (name?.isNotEmpty ?? false) ? name! : '店舗',
                    );
                  }).toList();
                }

                // ストリーム結果に現在選択が無ければ union
                if (tenantId != null && !options.any((e) => e.id == tenantId)) {
                  options = [
                    ...options,
                    TenantOption(id: tenantId!, name: tenantName ?? '店舗'),
                  ];
                }

                // ストリームが空っぽならフォールバック Future へ
                if (options.isEmpty) {
                  return FutureBuilder<List<TenantOption>>(
                    future: _loadTenantOptionsFallback(),
                    builder: (context, fb) {
                      final opts = fb.data ?? const <TenantOption>[];
                      return AppDrawer(
                        tenantName: tenantName,
                        currentTenantId: tenantId,
                        currentIndex: _currentIndex,
                        onTapIndex: (i) => setState(() => _currentIndex = i),
                        tenantOptions: opts,
                        onChangeTenant: (id) async => _handleChangeTenant(id),
                        onCreateTenant: () async => createTenantDialog(),
                      );
                    },
                  );
                }

                return AppDrawer(
                  tenantName: tenantName,
                  currentTenantId: tenantId,
                  currentIndex: _currentIndex,
                  onTapIndex: (i) => setState(() => _currentIndex = i),
                  tenantOptions: options,
                  onChangeTenant: (id) async => _handleChangeTenant(id),
                  onCreateTenant: () async => createTenantDialog(),
                );
              },
            )
          : null,

      body: tenantId == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: IndexedStack(
                    index: _currentIndex,
                    children: [
                      StoreHomeTab(tenantId: tenantId!, tenantName: tenantName),
                      StoreQrTab(tenantId: tenantId!, tenantName: tenantName),
                      StoreStaffTab(tenantId: tenantId!),
                      StoreSettingsTab(tenantId: tenantId!),
                    ],
                  ),
                ),
              ],
            ),

      bottomNavigationBar: isNarrow
          ? null
          : BottomNavigationBar(
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
                BottomNavigationBarItem(icon: Icon(Icons.group), label: 'スタッフ'),
                BottomNavigationBarItem(
                  icon: Icon(Icons.settings),
                  label: '設定',
                ),
              ],
            ),
    );
  }
}
