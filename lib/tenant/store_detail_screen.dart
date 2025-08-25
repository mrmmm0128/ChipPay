import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
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
  // ===== 決済タブの状態 =====
  final amountCtrl = TextEditingController(text: '1000');
  String? checkoutUrl;
  String? sessionId;
  String? publicStoreUrl;
  bool loading = false;
  int _currentIndex = 0; // 0: ホーム, 1: 決済履歴, 2: スタッフ, 3: 設定

  // ===== 共通：選択中の店舗 =====
  String? tenantId;
  String? tenantName;

  // ===== スタッフ追加ダイアログ用の状態 =====
  final _empNameCtrl = TextEditingController();
  final _empEmailCtrl = TextEditingController();

  bool _argsApplied = false;

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
        if (doc.exists)
          setState(() => tenantName = doc.data()!['name'] as String?);
      }
    }
  }

  // ====== 決済：セッション作成 ======
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
  }

  @override
  Widget build(BuildContext context) {
    // 画面タイトルはページごとに出し分け
    final titles = ['ホーム', 'QR', 'スタッフ', '設定'];
    final appTitle = titles[_currentIndex];
    final maxSwitcherW = (MediaQuery.of(context).size.width * 0.7).clamp(
      320.0,
      560.0,
    );
    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF7F7F7),
        foregroundColor: Colors.black87,
        automaticallyImplyLeading: false,
        elevation: 0,
        toolbarHeight: 60,
        titleSpacing: 16,
        title: Text(
          appTitle,
          overflow: TextOverflow.ellipsis, // ← タイトルは省略表示に
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxSwitcherW), // ← 左へ広げる
              child: TenantSwitcherBar(
                currentTenantId: tenantId,
                currentTenantName: tenantName,
                onChanged: (id, name) {
                  if (id == tenantId) return;
                  setState(() {
                    tenantId = id;
                    tenantName = name;
                  });
                },
              ),
            ),
          ),
          IconButton(
            tooltip: 'お知らせ',
            onPressed: () => {},
            icon: const Icon(
              Icons.notifications_outlined,
              color: Colors.black87,
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),

      // 中身はIndexedStackで状態保持
      body: tenantId == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // ★ コンテンツ
                Expanded(
                  child: (tenantId == null)
                      ? const _SelectOrCreatePlaceholder()
                      : IndexedStack(
                          index: _currentIndex,
                          children: [
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
            ),

      // ボトムバー
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

class _SelectOrCreatePlaceholder extends StatelessWidget {
  const _SelectOrCreatePlaceholder();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        '上のプルダウンから店舗を選択するか、新規作成してください',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: Colors.black87,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
