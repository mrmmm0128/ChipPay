// lib/tenant/widgets/tenant_switcher_bar.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';

class TenantSwitcherBar extends StatefulWidget {
  final String? currentTenantId;
  final String? currentTenantName;
  final void Function(String tenantId, String? tenantName) onChanged;

  /// 余白（控えめにデフォルト調整）
  final EdgeInsetsGeometry padding;

  const TenantSwitcherBar({
    super.key,
    required this.onChanged,
    this.currentTenantId,
    this.currentTenantName,
    this.padding = const EdgeInsets.fromLTRB(16, 8, 16, 6), // ★ smaller
  });

  @override
  State<TenantSwitcherBar> createState() => _TenantSwitcherBarState();
}

class _TenantSwitcherBarState extends State<TenantSwitcherBar> {
  final _functions = FirebaseFunctions.instanceFor(region: 'us-central1');

  late final String _uid = FirebaseAuth.instance.currentUser!.uid;
  String? _selectedId;

  Query<Map<String, dynamic>> _queryForUserTenants() {
    // TODO: 必要なら membership 条件に変更
    return FirebaseFirestore.instance
        .collection('tenants')
        .orderBy('createdAt', descending: true);
  }

  @override
  void initState() {
    super.initState();
    _selectedId = widget.currentTenantId;
  }

  @override
  void didUpdateWidget(covariant TenantSwitcherBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentTenantId != widget.currentTenantId) {
      _selectedId = widget.currentTenantId;
    }
  }

  // ---- ここが肝：白×黒テーマ（ポップアップ用のローカルテーマ） ----
  ThemeData _bwTheme(BuildContext context) {
    final base = Theme.of(context);
    final cs = base.colorScheme;
    OutlineInputBorder _border(Color c) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: c),
    );
    return base.copyWith(
      colorScheme: cs.copyWith(
        primary: Colors.black,
        secondary: Colors.black,
        surface: Colors.white,
        onSurface: Colors.black87,
        onPrimary: Colors.white,
        onSecondary: Colors.white,
        background: Colors.white,
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
        border: _border(Colors.black12),
        enabledBorder: _border(Colors.black12),
        focusedBorder: _border(Colors.black),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.black87,
          side: const BorderSide(color: Colors.black45),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: Colors.black87),
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: Colors.white,
        selectedColor: Colors.black12,
        labelStyle: const TextStyle(color: Colors.black87),
        side: const BorderSide(color: Colors.black26),
        showCheckmark: false,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: Colors.black,
      ),
      dividerColor: Colors.black12,
    );
  }

  // ---------- テナント作成ダイアログ ----------
  Future<void> createTenantDialog() async {
    final nameCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => Theme(
        // ここはこのダイアログ専用の白黒トーン（他画面へは影響なし）
        data: Theme.of(context).copyWith(
          colorScheme: Theme.of(context).colorScheme.copyWith(
            primary: Colors.black87,
            onPrimary: Colors.white,
            surfaceTint: Colors.transparent,
          ),
          textSelectionTheme: const TextSelectionThemeData(
            cursorColor: Colors.black87,
            selectionColor: Color(0x33000000),
            selectionHandleColor: Colors.black87,
          ),
        ),
        child: AlertDialog(
          backgroundColor: const Color(0xFFF5F5F5), // ★ 薄い灰色の背景
          surfaceTintColor: Colors.transparent, // ★ M3の色かぶり抑止
          titleTextStyle: const TextStyle(
            // ★ タイトル黒
            color: Colors.black87,
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ),
          contentTextStyle: const TextStyle(
            // ★ 本文黒
            color: Colors.black87,
            fontSize: 14,
          ),
          title: const Text('新しい店舗を作成'),
          content: TextField(
            controller: nameCtrl,
            autofocus: true,
            style: const TextStyle(color: Colors.black87), // ★ 入力文字黒
            decoration: InputDecoration(
              labelText: '店舗名',
              hintText: '例）渋谷店',
              labelStyle: const TextStyle(color: Colors.black87), // ★ ラベル黒
              hintStyle: const TextStyle(color: Colors.black54), // ★ ヒント濃いグレー
              filled: true,
              fillColor: Colors.white, // ★ 入力欄は白地
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 12,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Colors.black26),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Colors.black87, width: 1.2),
              ),
            ),
          ),
          actionsPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 8,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              style: TextButton.styleFrom(
                foregroundColor: Colors.black87, // ★ ボタン文字黒
              ),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.black, // ★ 黒ボタン
                foregroundColor: Colors.white, // ★ 白文字
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
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
          'members': [_uid],
          'status': 'active',
          'createdAt': FieldValue.serverTimestamp(),
          'createdBy': {
            'uid': _uid,
            'email': FirebaseAuth.instance.currentUser?.email,
          },
          'subscription': {'status': 'inactive', 'plan': 'A'},
        });
        if (!mounted) return;

        setState(() => _selectedId = ref.id);
        widget.onChanged(ref.id, name);

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Colors.white,
            content: Text('店舗を作成しました', style: TextStyle(color: Colors.black87)),
          ),
        );

        // 作成後にオンボーディング起動
        startOnboarding(ref.id, name);
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

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: widget.padding,
      child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: _queryForUserTenants().snapshots(),
        builder: (context, snap) {
          if (snap.hasError) {
            return _wrap(
              child: Text(
                '読み込みエラー: ${snap.error}',
                style: const TextStyle(color: Colors.red),
              ),
            );
          }
          if (!snap.hasData) {
            return _wrap(child: const LinearProgressIndicator(minHeight: 2));
          }

          final docs = snap.data!.docs;
          if (docs.isEmpty) {
            return _wrap(
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      '店舗がありません。作成してください。',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: Colors.black87,
                      ),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: createTenantDialog,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('店舗を作成'),
                    style: _outlineSmall,
                  ),
                ],
              ),
            );
          }

          final items = docs
              .map(
                (d) => DropdownMenuItem<String>(
                  value: d.id,
                  child: Text(
                    (d.data()['name'] ?? '(no name)').toString(),
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.black87),
                  ),
                ),
              )
              .toList();

          final ids = docs.map((d) => d.id).toSet();
          if (_selectedId == null || !ids.contains(_selectedId)) {
            _selectedId = docs.first.id;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              final first = docs.first;
              widget.onChanged(
                first.id,
                (first.data()['name'] ?? '') as String?,
              );
            });
          }

          return _wrap(
            child: Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    isExpanded: true,
                    isDense: true,
                    value: _selectedId,
                    items: items,
                    iconEnabledColor: Colors.black54,
                    dropdownColor: Colors.white,
                    style: const TextStyle(color: Colors.black87, fontSize: 14),
                    onChanged: (v) {
                      if (v == null) return;
                      setState(() => _selectedId = v);
                      final doc = docs.firstWhere((e) => e.id == v);
                      widget.onChanged(
                        v,
                        (doc.data()['name'] ?? '') as String?,
                      );
                    },
                    decoration: InputDecoration(
                      labelText: '店舗を選択',
                      labelStyle: const TextStyle(color: Colors.black87),
                      floatingLabelStyle: const TextStyle(color: Colors.black),
                      filled: true,
                      fillColor: Colors.white,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: Colors.black12),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: Colors.black12),
                      ),
                    ),
                    menuMaxHeight: 320,
                    alignment: Alignment.centerLeft,
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: createTenantDialog,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('新規作成'),
                  style: _outlineSmall,
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // 枠のみ・影なしの控えめラッパー
  Widget _wrap({required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.black12),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: child,
    );
  }

  ButtonStyle get _outlineSmall => OutlinedButton.styleFrom(
    foregroundColor: Colors.black87,
    side: const BorderSide(color: Colors.black45),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
    visualDensity: VisualDensity.compact,
  );
}

// ---- ボトムシート本体（分離して Theme 適用を確実に） ----
class OnboardingSheet extends StatefulWidget {
  final String tenantId;
  final String tenantName;
  final FirebaseFunctions functions;
  const OnboardingSheet({
    super.key,
    required this.tenantId,
    required this.tenantName,
    required this.functions,
  });

  @override
  State<OnboardingSheet> createState() => OnboardingSheetState();
}

class OnboardingSheetState extends State<OnboardingSheet> {
  /// 0: 初期費用, 1: サブスク, 2: Stripe Connect 同意＆作成, 3: メンバー招待
  int step = 0;

  // ---- Step1(サブスク) ----
  String selectedPlan = 'A';
  bool creatingSubCheckout = false;

  // ---- Step0(初期費用) ----
  bool creatingInitialFeeCheckout = false;

  // ---- Step2(Connect 同意＆作成) ----
  bool connectAgree = false;
  bool creatingConnect = false;
  bool checkingConnect = false;

  // ---- Step3(メンバー招待) ----
  final inviteCtrl = TextEditingController();
  final invitedEmails = <String>[];
  bool inviting = false;

  @override
  void dispose() {
    inviteCtrl.dispose();
    super.dispose();
  }

  // =========================================================
  // Step 0: 初期費用チェックアウトを開く
  // =========================================================
  Future<void> _openInitialFeeCheckout() async {
    if (creatingInitialFeeCheckout) return;
    setState(() => creatingInitialFeeCheckout = true);
    try {
      final res = await widget.functions
          .httpsCallable('createInitialFeeCheckout')
          .call({
            'tenantId': widget.tenantId,
            'email': FirebaseAuth.instance.currentUser?.email,
            'name': FirebaseAuth.instance.currentUser?.displayName,
          });
      final data = res.data as Map;

      final url = data['url'] as String?;
      if (url != null && url.isNotEmpty) {
        await launchUrlString(
          url,
          mode: LaunchMode.platformDefault,
          webOnlyWindowName: '_self', // 同タブ遷移
        );
      } else if (data['alreadyPaid'] == true) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('初期費用はすでにお支払い済みです')));
        setState(() => step = 1); // 次へ
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('初期費用リンクを取得できませんでした')));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('初期費用の決済開始に失敗: $e')));
    } finally {
      if (mounted) setState(() => creatingInitialFeeCheckout = false);
    }
  }

  // =========================================================
  // Step 1: サブスク（プラン選択→Checkout）
  // =========================================================
  Future<void> _openSubscriptionCheckout() async {
    if (creatingSubCheckout) return;
    setState(() => creatingSubCheckout = true);
    try {
      final res = await widget.functions
          .httpsCallable('createSubscriptionCheckout')
          .call({
            'tenantId': widget.tenantId,
            'plan': selectedPlan,
            'email': FirebaseAuth.instance.currentUser?.email,
            'name': FirebaseAuth.instance.currentUser?.displayName,
          });
      final data = res.data as Map;

      if (data['alreadySubscribed'] == true && data['portalUrl'] != null) {
        await launchUrlString(
          data['portalUrl'],
          mode: LaunchMode.platformDefault,
          webOnlyWindowName: '_self',
        );
      } else if (data['url'] != null) {
        await launchUrlString(
          data['url'],
          mode: LaunchMode.platformDefault,
          webOnlyWindowName: '_self',
        );
      } else {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('サブスクのリンクを取得できませんでした')));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('チェックアウト作成に失敗: $e')));
      }
    } finally {
      if (mounted) setState(() => creatingSubCheckout = false);
    }
  }

  // =========================================================
  // Step 2: Stripe Connect 同意＆作成
  // =========================================================
  Future<void> _openConnectOnboarding() async {
    if (!connectAgree || creatingConnect) return;
    setState(() => creatingConnect = true);
    try {
      final caller = widget.functions.httpsCallable('upsertConnectedAccount');
      final payload = {
        'tenantId': widget.tenantId,
        'account': {
          'country': 'JP',
          'businessType': 'individual', // or 'company'
          'email': FirebaseAuth.instance.currentUser?.email,
          'businessProfile': {'product_description': 'チップ受け取り（チッププラットフォーム）'},
          'tosAccepted': true,
        },
      };
      final res = await caller.call(payload);
      final data = (res.data as Map?) ?? {};
      final onboardingUrl = data['onboardingUrl'] as String?;
      final chargesEnabled = data['chargesEnabled'] == true;
      final payoutsEnabled = data['payoutsEnabled'] == true;

      if (onboardingUrl != null && onboardingUrl.isNotEmpty) {
        await launchUrlString(
          onboardingUrl,
          mode: LaunchMode.platformDefault,
          webOnlyWindowName: '_self',
        );
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Stripe接続が更新されました')));
        // Firestore 側更新を拾って自動遷移するのでここでは遷移しない
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Stripe接続の開始に失敗: $e')));
    } finally {
      if (mounted) setState(() => creatingConnect = false);
    }
  }

  Future<void> _checkConnectLatest() async {
    if (checkingConnect) return;
    setState(() => checkingConnect = true);
    try {
      final doc = await FirebaseFirestore.instance
          .collection('tenants')
          .doc(widget.tenantId)
          .get();
      final c = (doc.data()?['connect'] as Map?) ?? {};
      final ok =
          (c['charges_enabled'] == true) && (c['payouts_enabled'] == true);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ok ? '接続は有効です' : 'まだ提出が必要です')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('状態の取得に失敗: $e')));
    } finally {
      if (mounted) setState(() => checkingConnect = false);
    }
  }

  // =========================================================
  // Step 3: メンバー招待
  // =========================================================
  Future<void> _inviteMember() async {
    final email = inviteCtrl.text.trim();
    if (email.isEmpty || inviting) return;
    setState(() => inviting = true);

    try {
      await widget.functions.httpsCallable('inviteTenantAdmin').call({
        'tenantId': widget.tenantId,
        'email': email,
      });
      setState(() {
        invitedEmails.add(email);
        inviteCtrl.clear();
      });
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('招待を送信しました: $email')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('招待に失敗: $e')));
      }
    } finally {
      if (mounted) setState(() => inviting = false);
    }
  }

  // =========================================================
  // UI（Firestore のテナント状態を監視し、自動で次ステップへ進める）
  // =========================================================
  @override
  Widget build(BuildContext context) {
    final tenantStream = FirebaseFirestore.instance
        .collection('tenants')
        .doc(widget.tenantId)
        .snapshots();

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: tenantStream,
      builder: (context, snap) {
        final m = snap.data?.data() ?? {};

        // ---- 進行度の判定（Webhook/バックエンド更新を拾う）----
        final billing = (m['billing'] as Map?) ?? {};
        final initialFee =
            (billing['initialFee'] as Map?) ?? (m['initialFee'] as Map? ?? {});
        final bool initialFeePaid = (initialFee['paid'] == true);

        final sub = (m['subscription'] as Map?) ?? {};
        final String subStatus = (sub['status'] as String? ?? '').toLowerCase();
        final bool subscriptionActive =
            (subStatus == 'active' || subStatus == 'trialing');

        final connect = (m['connect'] as Map?) ?? {};
        final bool chargesEnabled = connect['charges_enabled'] == true;
        final bool payoutsEnabled = connect['payouts_enabled'] == true;
        final bool connectOk = chargesEnabled && payoutsEnabled;

        // ---- 自動ステップ進行（現在ステップを上書き）----
        int desiredStep = step;
        if (desiredStep == 0 && initialFeePaid) desiredStep = 1;
        if (desiredStep <= 1 && subscriptionActive) desiredStep = 2;
        if (desiredStep <= 2 && connectOk) desiredStep = 3;
        if (desiredStep != step) {
          // build 中の setState を避けるためフレーム後に反映
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => step = desiredStep);
          });
        }

        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.78,
          minChildSize: 0.5,
          maxChildSize: 0.96,
          builder: (context, scroll) {
            return SingleChildScrollView(
              controller: scroll,
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ドラッグハンドル
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.black26,
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '店舗オンボーディング',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    widget.tenantName,
                    style: const TextStyle(fontSize: 13, color: Colors.black54),
                  ),
                  const SizedBox(height: 16),

                  // ステップ表示
                  _StepsBar(
                    steps: const ['初期費用', 'サブスク', 'Stripe接続', 'メンバー'],
                    activeIndex: step,
                    done: [
                      initialFeePaid,
                      subscriptionActive,
                      connectOk,
                      false,
                    ],
                  ),
                  const SizedBox(height: 16),

                  if (step == 0) _buildInitialFeeStepUI(initialFeePaid),
                  if (step == 1) _buildSubscriptionStepUI(subscriptionActive),
                  if (step == 2)
                    _buildConnectStepUI(
                      chargesEnabled: chargesEnabled,
                      payoutsEnabled: payoutsEnabled,
                    ),
                  if (step == 3) _buildInviteStepUI(),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // ---- Step 0 UI: 初期費用 ----
  Widget _buildInitialFeeStepUI(bool alreadyPaid) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'まずは初期費用のお支払いをお願いします。\n同じテナントは同じプラットフォームのカスタマーで管理されます。',
          style: TextStyle(color: Colors.black87),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: (creatingInitialFeeCheckout || alreadyPaid)
                    ? null
                    : _openInitialFeeCheckout,
                icon: creatingInitialFeeCheckout
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.open_in_new),
                label: Text(alreadyPaid ? '支払い済み' : '初期費用を支払う'),
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton(
              onPressed: () => setState(() => step = 1),
              child: const Text('あとで'),
            ),
          ],
        ),
      ],
    );
  }

  // ---- Step 1 UI: サブスク ----
  Widget _buildSubscriptionStepUI(bool subActive) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'プランを選択し、登録へ進んでください。',
          style: TextStyle(color: Colors.black87),
        ),
        const SizedBox(height: 12),
        _planChips(),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: (creatingSubCheckout || subActive)
                    ? null
                    : _openSubscriptionCheckout,
                icon: creatingSubCheckout
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.open_in_new),
                label: Text(subActive ? '登録済み' : 'サブスク登録へ進む'),
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton(
              onPressed: () => setState(() => step = 2),
              child: const Text('あとで'),
            ),
          ],
        ),
      ],
    );
  }

  // ---- Step 2 UI: Connect 同意＆作成 ----
  Widget _buildConnectStepUI({
    required bool chargesEnabled,
    required bool payoutsEnabled,
  }) {
    final ok = chargesEnabled && payoutsEnabled;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'チップを受け取るには、Stripeの「コネクトアカウント」が必要です。\n'
          '本人確認書類や銀行口座の登録を含みます（Stripe に安全に送信され、当社サーバーには保存されません）。',
          style: TextStyle(color: Colors.black87),
        ),
        const SizedBox(height: 12),
        CheckboxListTile(
          value: connectAgree,
          onChanged: ok
              ? null
              : (v) => setState(() => connectAgree = v ?? false),
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text(
            '上記の説明に同意し、Stripe接続を開始します',
            style: TextStyle(color: Colors.black87),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: (ok || !connectAgree || creatingConnect)
                    ? null
                    : _openConnectOnboarding,
                icon: creatingConnect
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.login),
                label: Text(ok ? '接続済み' : 'Stripe接続に進む'),
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: checkingConnect ? null : _checkConnectLatest,
              icon: checkingConnect
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync),
              label: const Text('接続状態を確認'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        _connectStatusPill(charges: chargesEnabled, payouts: payoutsEnabled),
        const SizedBox(height: 16),
        Row(
          children: [
            OutlinedButton(
              onPressed: step > 0 ? () => setState(() => step -= 1) : null,
              child: const Text('戻る'),
            ),
            const Spacer(),
            FilledButton(
              onPressed: () => setState(() => step = 3),
              child: const Text('次へ'),
            ),
          ],
        ),
      ],
    );
  }

  // ---- Step 3 UI: メンバー招待 ----
  Widget _buildInviteStepUI() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '店舗の管理者/スタッフをメールで招待できます。',
          style: TextStyle(color: Colors.black87),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: inviteCtrl,
          decoration: const InputDecoration(
            labelText: 'メールアドレス',
            hintText: 'example@domain.com',
          ),
          keyboardType: TextInputType.emailAddress,
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: inviting ? null : _inviteMember,
                icon: inviting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send),
                label: const Text('招待を送信'),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('完了'),
            ),
          ],
        ),
        if (invitedEmails.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Text('送信済み招待:', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: invitedEmails
                .map(
                  (e) => Chip(
                    label: Text(
                      e,
                      style: const TextStyle(color: Colors.black87),
                    ),
                    visualDensity: VisualDensity.compact,
                    side: const BorderSide(color: Colors.black26),
                    backgroundColor: Colors.white,
                  ),
                )
                .toList(),
          ),
        ],
        const SizedBox(height: 8),
        Row(
          children: [
            OutlinedButton(
              onPressed: step > 0 ? () => setState(() => step -= 1) : null,
              child: const Text('戻る'),
            ),
            const Spacer(),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('閉じる'),
            ),
          ],
        ),
      ],
    );
  }

  // ---- パーツ：プラン表示（ChoiceChip）
  Widget _planChips() {
    const plans = <_Plan>[
      _Plan(
        code: 'A',
        title: 'Aプラン',
        monthly: 0,
        feePct: 20,
        features: ['月額無料で今すぐ開始', '決済手数料は20%', 'まずはお試しに最適'],
      ),
      _Plan(
        code: 'B',
        title: 'Bプラン',
        monthly: 1980,
        feePct: 15,
        features: ['月額1,980円で手数料15%', 'コストと手数料のバランス◎', '小規模〜標準的な店舗向け'],
      ),
      _Plan(
        code: 'C',
        title: 'Cプラン',
        monthly: 9800,
        feePct: 10,
        features: ['月額9,800円で手数料10%', 'Googleレビュー導線の設置', '公式LINEの友だち追加導線'],
      ),
    ];

    Widget item(_Plan p) {
      final sel = selectedPlan == p.code;
      final fg = sel ? Colors.white : Colors.black87;
      return ChoiceChip(
        selected: sel,
        onSelected: (_) => setState(() => selectedPlan = p.code),
        backgroundColor: Colors.white,
        selectedColor: Colors.black,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: sel ? Colors.black : Colors.black26),
        ),
        label: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 220),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
            child: DefaultTextStyle(
              style: TextStyle(color: fg, fontSize: 13),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 上段：コード/タイトル/料金
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: sel ? Colors.white : Colors.black,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          p.code,
                          style: TextStyle(
                            color: sel ? Colors.black : Colors.white,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          p.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: fg,
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        p.monthly == 0 ? '無料' : '¥${p.monthly}/月',
                        style: TextStyle(
                          color: fg,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '手数料 ${p.feePct}%',
                    style: TextStyle(color: fg.withOpacity(.8)),
                  ),
                  const SizedBox(height: 6),
                  ...p.features
                      .take(3)
                      .map(
                        (f) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1.5),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(Icons.check, size: 14, color: fg),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  f,
                                  style: TextStyle(color: fg, height: 1.2),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: plans.map(item).toList(),
    );
  }

  // ---- パーツ：接続ステータス表示
  Widget _connectStatusPill({required bool charges, required bool payouts}) {
    Widget pill(String label, bool ok) {
      final c = ok ? Colors.green : Colors.red;
      final icon = ok ? Icons.check_circle : Icons.error;
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: c.withOpacity(.1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: c.withOpacity(.6)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: c),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(color: c, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        pill('決済(Charges): ${charges ? 'OK' : 'NG'}', charges),
        pill('出金(Payouts): ${payouts ? 'OK' : 'NG'}', payouts),
      ],
    );
  }
}

// ---- ステップバー（ドット型＋完了状態）
class _StepsBar extends StatelessWidget {
  final List<String> steps;
  final int activeIndex;
  final List<bool> done;
  const _StepsBar({
    required this.steps,
    required this.activeIndex,
    required this.done,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (int i = 0; i < steps.length; i++) ...[
          _StepDot(active: i == activeIndex, done: done[i], label: steps[i]),
          if (i < steps.length - 1)
            const Icon(Icons.chevron_right, size: 18, color: Colors.black38),
        ],
      ],
    );
  }
}

class _StepDot extends StatelessWidget {
  final bool active;
  final bool done;
  final String label;
  const _StepDot({
    required this.active,
    required this.done,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final bg = done ? Colors.green : (active ? Colors.black : Colors.white);
    final fg = done ? Colors.white : (active ? Colors.white : Colors.black54);
    final icon = done
        ? Icons.check
        : (active ? Icons.radio_button_checked : Icons.circle_outlined);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            color: bg,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.black),
          ),
          child: Icon(icon, size: 12, color: fg),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(color: Colors.black87, fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}

// ---- サポート用ミニモデル
class _Plan {
  final String code;
  final String title;
  final int monthly; // JPY
  final int feePct; // %
  final List<String> features;
  const _Plan({
    required this.code,
    required this.title,
    required this.monthly,
    required this.feePct,
    required this.features,
  });
}
