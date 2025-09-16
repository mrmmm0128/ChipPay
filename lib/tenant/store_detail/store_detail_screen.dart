// lib/tenant/store_detail_screen.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:yourpay/tenant/newTenant/onboardingSheet.dart';
import 'package:yourpay/tenant/widget/store_home/drawer.dart';
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
  // ---- global guards (インスタンスを跨いで1回だけ動かすためのフラグ) ----
  static bool _globalOnboardingOpen = false;
  static bool _globalStripeEventHandled = false;

  // ---- state ----
  final amountCtrl = TextEditingController(text: '1000');
  final _functions = FirebaseFunctions.instanceFor(region: 'us-central1');

  bool loading = false;
  int _currentIndex = 0;

  // 管理者判定
  static const Set<String> _kAdminEmails = {'appfromkomeda@gmail.com'};
  bool _isAdmin = false;

  String? tenantId;
  String? tenantName;
  bool _loggingOut = false;
  bool _loading = true;
  String? ownerUid;
  bool invited = false;

  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _empNameCtrl = TextEditingController();
  final _empEmailCtrl = TextEditingController();

  bool _onboardingOpen = false; // インスタンス内ガード

  bool _argsApplied = false; // ルート引数適用済み
  bool _tenantInitialized = false; // 初回テナント確定済み
  bool _stripeHandled = false; // インスタンス内のStripeイベント処理済み

  // Stripeイベントの保留（初期化完了後に1回だけ処理）
  String? _pendingStripeEvt;
  String? _pendingStripeTenant;
  late User user;

  // 初期テナント解決用 Future（※毎buildで新規作成しない）
  Future<Map<String, String?>?>? _initialTenantFuture;

  Future<void> _openAlertsPanel() async {
    final tid = tenantId;
    if (tid == null) return;

    // 1) ownerUid を tenantIndex から取得（招待テナント対応）
    String? ownerUid;
    try {
      final idx = await FirebaseFirestore.instance
          .collection('tenantIndex')
          .doc(tid)
          .get();
      ownerUid = idx.data()?['uid'] as String?;
    } catch (_) {}
    // 自分オーナーのケースのフォールバック
    ownerUid ??= FirebaseAuth.instance.currentUser?.uid;

    if (ownerUid == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('通知の取得に失敗しました（ownerUid 不明）')),
      );
      return;
    }

    // 2) alerts を新しい順で取得
    final col = FirebaseFirestore.instance
        .collection(ownerUid)
        .doc(tid)
        .collection('alerts');

    final qs = await col.orderBy('createdAt', descending: true).limit(50).get();

    final alerts = qs.docs.map((d) => {'id': d.id, ...d.data()}).toList();

    // 3) 未読を既読に（表示するタイミングで一括マーク）
    if (alerts.isNotEmpty) {
      final batch = FirebaseFirestore.instance.batch();
      for (final d in qs.docs) {
        final read = (d.data()['read'] as bool?) ?? false;
        if (!read) {
          batch.set(d.reference, {
            'read': true,
            'readAt': FieldValue.serverTimestamp(),
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
        }
      }
      await batch.commit();
    }

    if (!mounted) return;

    // 4) 一覧を BottomSheet で表示（message, createdAt を軽く表示）
    await showModalBottomSheet(
      context: context,
      isScrollControlled: false,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  height: 4,
                  width: 40,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Colors.black12,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'お知らせ',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      fontFamily: 'LINEseed',
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                if (alerts.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Text('新しいお知らせはありません'),
                  )
                else
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: alerts.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (ctx, i) {
                        final a = alerts[i];
                        final msg = (a['message'] as String?)?.trim();
                        final createdAt = a['createdAt'];
                        String when = '';
                        if (createdAt is Timestamp) {
                          final dt = createdAt.toDate().toLocal();
                          // シンプルな表示（intl なしで）
                          when =
                              '${dt.year}/${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')} '
                              '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
                        }

                        return ListTile(
                          leading: const Icon(Icons.notifications),
                          title: Text(
                            (msg == null || msg.isEmpty) ? 'お知らせ' : msg,
                            style: const TextStyle(fontFamily: 'LINEseed'),
                          ),
                          subtitle: when.isEmpty ? null : Text(when),
                          dense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 0,
                            vertical: 4,
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Map<String, String> _queryFromHashAndSearch() {
    final u = Uri.base;
    final map = <String, String>{}..addAll(u.queryParameters);
    final frag = u.fragment; // 例: "/store?event=...&t=..."
    final qi = frag.indexOf('?');
    if (qi >= 0) {
      map.addAll(Uri.splitQueryString(frag.substring(qi + 1)));
    }
    return map;
  }

  // ---- theme (白黒) ----
  ThemeData _bwTheme(BuildContext context) {
    final base = Theme.of(context);
    const lineSeedFamily = 'LINEseed';

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
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        selectedLabelStyle: TextStyle(
          fontFamily: lineSeedFamily,
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
        unselectedLabelStyle: TextStyle(
          fontFamily: lineSeedFamily,
          fontWeight: FontWeight.w500,
          fontSize: 12,
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    // 初回だけ Future を生成（以降は使い回す）
    user = FirebaseAuth.instance.currentUser!;
    print(user);

    if (user != null && !_tenantInitialized) {
      _initialTenantFuture = _resolveInitialTenant(user);
    }
    ownerUid = user.uid;
    // 初期化中は setState しない。完了後に必要なら1回だけ反映する。
    _checkAdmin();
    _loading = false;
  }

  Future<List<Map<String, dynamic>>> checkAlerts({
    required String ownerUid,
    required String tenantId,
    int limit = 50,
  }) async {
    final snap = await FirebaseFirestore.instance
        .collection(ownerUid)
        .doc(tenantId)
        .collection('alerts')
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .get();

    return snap.docs.map((d) => {'id': d.id, ...d.data()}).toList();
  }

  // ★ 初期化完了前は setState しないで代入のみ。完了後に変化があれば setState。
  Future<void> _checkAdmin() async {
    if (user == null) return;

    final token = await user.getIdTokenResult(); // 強制リフレッシュしない
    final email = (user.email ?? '').toLowerCase();

    final newIsAdmin =
        (token.claims?['admin'] == true) || _kAdminEmails.contains(email);

    if (!_tenantInitialized) {
      _isAdmin = newIsAdmin;
      return;
    }
    if (mounted && _isAdmin != newIsAdmin) {
      setState(() => _isAdmin = newIsAdmin);
    }
  }

  Future<void> logout() async {
    if (_loggingOut) return;
    setState(() => _loggingOut = true);
    try {
      await FirebaseAuth.instance.signOut();

      if (!mounted) return;

      // Drawerが開いていれば閉じる（任意）
      if (_scaffoldKey.currentState?.isDrawerOpen ?? false) {
        _scaffoldKey.currentState!.closeDrawer();
      }

      // 画面スタックを全消しして /login (BootGate) へ
      Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('ログアウトに失敗: $e')));
    } finally {
      if (mounted) setState(() => _loggingOut = false);
    }
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
        // 作成直後の setState 内
        setState(() {
          tenantId = ref.id;
          tenantName = name;
          ownerUid = user.uid; // ← 追加（自分のテナント）
          invited = false;
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

  // ---- オンボーディング（グローバル/ローカル両方でガード）----
  Future<void> startOnboarding(String tenantId, String tenantName) async {
    if (_onboardingOpen || _globalOnboardingOpen) return; // 二重起動ガード
    _onboardingOpen = true;
    _globalOnboardingOpen = true;
    try {
      await showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.white,
        useRootNavigator: true,
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
    } finally {
      // クローズ後に必ず解除
      _onboardingOpen = false;
      _globalOnboardingOpen = false;
    }
  }

  // ---- ルート引数適用 & Stripe戻りURL処理（初期化前は“代入のみ”で setState しない）----
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_argsApplied) {
      _argsApplied = true;
      final args = ModalRoute.of(context)?.settings.arguments;
      if (args is Map) {
        final id = args['tenantId'] as String?;
        final nameArg = args['tenantName'] as String?;
        final oUid = args['ownerUid'] as String?; // ← 追加（あれば優先）

        if (id != null && id.isNotEmpty) {
          // ★ BootGate から来たテナントをそのまま採用して
          //   初期テナント解決(FutureBuilder)をスキップする
          tenantId = id;
          tenantName = nameArg;
          ownerUid = oUid ?? ownerUid; // 無ければ既定の user.uid のまま
          _tenantInitialized = true; // ← これがポイント

          // Stripeイベントを保留していた場合は、初期化済みになった今処理する
          if (_pendingStripeEvt != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _handleStripeEventNow();
            });
          }
        }
      }
    }

    // Stripe 戻りURLを確認（初期化前は保留、後で1回だけ処理）
    if (!_stripeHandled && !_globalStripeEventHandled) {
      final q = _queryFromHashAndSearch();
      final evt = q['event'];
      final t = q['t'] ?? q['tenantId'];
      final hasStripeEvent =
          (evt == 'initial_fee_paid' || evt == 'initial_fee_canceled');

      if (hasStripeEvent) {
        _stripeHandled = true;
        _globalStripeEventHandled = true;
        _pendingStripeEvt = evt;
        _pendingStripeTenant = t;

        if (_tenantInitialized) {
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _handleStripeEventNow(),
          );
        }
      }
    }
  }

  // ---- 初回テナント推定（Future内で完結。setStateはしない）----
  Future<Map<String, String?>?> _resolveInitialTenant(User user) async {
    if (tenantId != null) return {'id': tenantId, 'name': tenantName};
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
          if (doc.exists) name = (doc.data()?['name'] as String?);
        } catch (_) {}
        return {'id': idFromClaims, 'name': name};
      }
    } catch (_) {}
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
    return null;
  }

  // ---- Stripeイベントを“今”実行（初期化後に1回だけ）----
  Future<void> _handleStripeEventNow() async {
    final evt = _pendingStripeEvt;
    final t = _pendingStripeTenant;
    _pendingStripeEvt = null;
    _pendingStripeTenant = null;

    if (t != null && t.isNotEmpty) {
      if (mounted) {
        setState(() => tenantId = t);
      } else {
        tenantId = t;
      }
    }
    if (evt == 'initial_fee_paid' && tenantId != null && mounted) {
      await startOnboarding(tenantId!, tenantName ?? '');
    }
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
    // ★ ここで固定ユーザーを取得（以降は auth の stream で再ビルドしない）
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return Theme(
        data: _bwTheme(context),
        child: const Scaffold(body: Center(child: Text('ログインが必要です'))),
      );
    }

    // まだ初期テナント未確定なら、一度だけ作った Future で描画
    if (!_tenantInitialized) {
      return Theme(
        data: _bwTheme(context),
        child: FutureBuilder<Map<String, String?>?>(
          future: _initialTenantFuture,
          builder: (context, tSnap) {
            if (tSnap.connectionState == ConnectionState.waiting) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }

            final resolved = tSnap.data;
            _tenantInitialized = true;
            if (resolved != null) {
              tenantId = resolved['id'];
              tenantName = resolved['name'];
            }

            // 初期化完了後、保留中のStripeイベントを“1回だけ”適用
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => _handleStripeEventNow(),
            );

            return _buildScaffold(context, user);
          },
        ),
      );
    }

    // 初期化済みなら通常描画（FutureBuilderを通さない）
    return Theme(data: _bwTheme(context), child: _buildScaffold(context, user));
  }

  // ---- Scaffoldの本体（安定化のため分離）----
  Widget _buildScaffold(BuildContext context, User user) {
    final size = MediaQuery.of(context).size;
    final isNarrow = size.width < 480;
    final maxSwitcherW = (size.width * 0.7).clamp(280.0, 560.0);

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
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset("assets/posters/tipri.png", height: 22),
            if (_isAdmin) const SizedBox(width: 8),
            if (_isAdmin)
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context).pushNamed('/admin'),
                icon: const Icon(Icons.admin_panel_settings, size: 18),
                label: const Text(
                  '管理者ページへ',
                  style: TextStyle(fontFamily: 'LINEseed'),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.black,
                  side: const BorderSide(color: Colors.black26),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  shape: const StadiumBorder(),
                  textStyle: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
          ],
        ),

        leading: isNarrow ? const DrawerButton() : null,
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
                    // 従来（後方互換）
                    if (id == tenantId) return;
                    setState(() {
                      tenantId = id;
                      tenantName = name;
                      ownerUid = user.uid; // ← 従来自テナント扱い
                      invited = false;
                    });
                  },
                  // ★ 追加：拡張コールバック
                  onChangedEx: (id, name, oUid, isInvited) {
                    if (id == tenantId && oUid == ownerUid) return;
                    setState(() {
                      tenantId = id;
                      tenantName = name;
                      ownerUid = oUid; // ← 実体のオーナーUIDを保持
                      invited = isInvited;
                    });
                  },
                ),
              ),
            ),
          IconButton(
            onPressed: tenantId == null ? null : _openAlertsPanel,
            icon: const Icon(Icons.notifications_outlined),
          ),
        ],
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: SizedBox(height: 1, child: ColoredBox(color: Colors.black12)),
        ),
      ),

      body: hasTenant
          ? SafeArea(
              child: IndexedStack(
                index: _currentIndex,
                children: [
                  StoreHomeTab(
                    tenantId: tenantId!,
                    tenantName: tenantName,
                    ownerId: ownerUid!,
                  ),
                  StoreQrTab(
                    tenantId: tenantId!,
                    tenantName: tenantName,
                    ownerId: ownerUid!,
                  ),
                  StoreStaffTab(tenantId: tenantId!, ownerId: ownerUid!),
                  StoreSettingsTab(tenantId: tenantId!, ownerId: ownerUid!),
                ],
              ),
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
                  Container(
                    margin: const EdgeInsets.symmetric(
                      vertical: 8,
                      horizontal: 16,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border.all(color: Colors.black26),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(999),
                      onTap: logout,
                      child: const Padding(
                        padding: EdgeInsets.symmetric(
                          vertical: 12,
                          horizontal: 20,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.logout, color: Colors.black87, size: 18),
                            SizedBox(width: 8),
                            Text(
                              'ログアウト',
                              style: TextStyle(
                                color: Colors.black87,
                                fontWeight: FontWeight.w700,
                                fontFamily: "LINEseed",
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
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
          BottomNavigationBarItem(icon: Icon(Icons.qr_code_2), label: '印刷'),
          BottomNavigationBarItem(icon: Icon(Icons.group), label: 'スタッフ'),
          BottomNavigationBarItem(icon: Icon(Icons.settings), label: '設定'),
        ],
      ),
    );
  }
}
