import 'dart:async';
import 'dart:html' as html;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';

class OnboardingSheet extends StatefulWidget {
  final String tenantId; // tempTenantId（createTenantDialogで採番した予約ID）
  final String tenantName; // 入力済みの店舗名
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
  int step = 0;

  // 進捗・選択
  String selectedPlan = "A";
  bool _initialFeePaidLocal = false;
  bool _subscribedLocal = false;

  // UIフラグ
  bool _creatingInitial = false;
  bool _creatingSub = false;
  bool _creatingConnect = false;
  bool _checkingConnect = false;
  bool _savingDraft = false;
  bool _savingFinal = false;
  bool _registered = false;

  // 下書き関連
  bool _hasDraft = false;
  DateTime? _draftUpdatedAt;

  // ---- 追加：リアルタイム連携（他タブ通知／フォーカス復帰） ----
  html.BroadcastChannel? _bc;
  StreamSubscription<html.MessageEvent>? _postMessageSub;
  StreamSubscription<html.Event>? _focusSub;

  // ---- 追加：ドラフト監視（uid/{tenantId} の変化も即反映）----
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _draftSub;

  late final String uid;

  @override
  void initState() {
    super.initState();
    uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    _loadDraft(); // 既存下書きの反映
    _setupRealtimeBridges(); // ← 追加：決済完了通知＆フォーカス復帰で再取得
    _subscribeDraftChanges(); // ← 追加：ドラフトの変更も画面に反映
  }

  @override
  void dispose() {
    _bc?.close();
    _postMessageSub?.cancel();
    _focusSub?.cancel();
    _draftSub?.cancel();
    super.dispose();
  }

  // ===== 下書きの読み込み =====
  Future<void> _loadDraft() async {
    if (uid.isEmpty) return;
    try {
      final snap = await FirebaseFirestore.instance
          .collection(uid)
          .doc(widget.tenantId)
          .get();

      if (!snap.exists) {
        setState(() {
          _hasDraft = false;
          _draftUpdatedAt = null;
        });
        return;
      }

      final data = snap.data() ?? {};
      final status = (data['status'] as String?) ?? 'nonactive';
      final sub = (data['subscription'] as Map?) ?? {};
      final plan = (sub['plan'] as String?) ?? selectedPlan;
      final subStatus = (sub['status'] as String?)?.toLowerCase() ?? 'inactive';
      final initial = (data['initialFee'] as Map?) ?? {};
      final initialPaid = (initial['status'] as String?) == 'paid';

      setState(() {
        _hasDraft = (status == 'nonactive');
        selectedPlan = plan;
        _initialFeePaidLocal = initialPaid;
        _subscribedLocal = (subStatus == 'active' || subStatus == 'trialing');
        _draftUpdatedAt = (snap.data()?['updatedAt'] is Timestamp)
            ? (snap.data()?['updatedAt'] as Timestamp).toDate()
            : null;
      });
    } catch (_) {
      // 読み込み失敗は無視（UIのみ影響）
    }
  }

  // ===== 追加：ドラフト変更の購読（uid/{tenantId}）=====
  void _subscribeDraftChanges() {
    if (uid.isEmpty) return;
    _draftSub = FirebaseFirestore.instance
        .collection(uid)
        .doc(widget.tenantId)
        .snapshots()
        .listen((snap) {
          if (!mounted || !snap.exists) return;
          final data = snap.data()!;
          final sub = (data['subscription'] as Map?) ?? {};
          final subStatus =
              (sub['status'] as String?)?.toLowerCase() ?? 'inactive';
          final initial = (data['initialFee'] as Map?) ?? {};
          final initialPaid = (initial['status'] as String?) == 'paid';
          final plan = (sub['plan'] as String?) ?? selectedPlan;

          setState(() {
            _hasDraft =
                ((data['status'] as String?) ?? 'nonactive') == 'nonactive';
            _initialFeePaidLocal = initialPaid;
            _subscribedLocal =
                (subStatus == 'active' || subStatus == 'trialing');
            selectedPlan = plan;
            _draftUpdatedAt = (data['updatedAt'] is Timestamp)
                ? (data['updatedAt'] as Timestamp).toDate()
                : _draftUpdatedAt;
          });
        });
  }

  // ===== 追加：他タブからの完了通知＆タブ復帰時の再読込 =====
  void _setupRealtimeBridges() {
    // BroadcastChannel（成功URL側から postMessage を送ってもらう）
    // 例: 成功ページで new BroadcastChannel('onboarding_${tenantId}').postMessage({kind:'subscription', status:'active'})
    _bc = html.BroadcastChannel('onboarding_${widget.tenantId}');
    _bc!.onMessage.listen((event) {
      _handleExternalSignal(event.data);
    });

    // window.postMessage 受信（成功ページが window.opener/postMessage の場合）
    _postMessageSub = html.window.onMessage.listen((event) {
      // 期待フォーマット: {source:'stripe-bridge', tenantId:'...', kind:'initial_fee|subscription|connect', status:'paid|active|updated'}
      _handleExternalSignal(event.data);
    });

    // タブ復帰（focus）時は Firestore の最新を取り直して即時UI更新（Webhook遅延のフォールバック）
    _focusSub = html.window.onFocus.listen((_) => _refreshFromServer());
  }

  void _handleExternalSignal(dynamic data) {
    if (data is! Map) return;
    if (data['tenantId'] != widget.tenantId) return;

    final kind = data['kind'] as String?;
    final status = (data['status'] as String?)?.toLowerCase();

    bool changed = false;

    if (kind == 'initial_fee' && status == 'paid') {
      _initialFeePaidLocal = true;
      changed = true;
    }
    if (kind == 'subscription' &&
        (status == 'active' || status == 'trialing')) {
      _subscribedLocal = true;
      changed = true;
    }
    if (kind == 'connect' && status == 'updated') {
      // Connect は tenants/{id}.connect を読むので即リフレッシュ
      _refreshFromServer();
    }

    if (changed && mounted) setState(() {});
  }

  Future<void> _refreshFromServer() async {
    try {
      // tenants/{id} を直接読み直して、Webhook反映を素早くUIに反映
      final t = await FirebaseFirestore.instance
          .collection(uid)
          .doc(widget.tenantId)
          .get();

      if (!mounted) return;
      final m = t.data() ?? {};
      final billing = (m['billing'] as Map?) ?? {};
      final initialFeePaid =
          (((billing['initialFee'] as Map?) ?? {})['status']) == 'paid';
      final sub = (m['subscription'] as Map?) ?? {};
      final subStatus = (sub['status'] as String? ?? '').toLowerCase();
      final subscribed = (subStatus == 'active' || subStatus == 'trialing');

      setState(() {
        _initialFeePaidLocal = _initialFeePaidLocal || initialFeePaid;
        _subscribedLocal = _subscribedLocal || subscribed;
        _registered = _registered || t.exists;
      });
    } catch (_) {
      // 無視（次のストリームで追いつく）
    }

    // ついでにドラフトも拾う（途中保存している場合）
    await _loadDraft();
  }

  // ====== アクション：初期費用 ======
  Future<void> _openInitialFeeCheckout() async {
    if (_creatingInitial) return;
    setState(() => _creatingInitial = true);

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
          webOnlyWindowName: '_self',
        );
      } else if (data['alreadyPaid'] == true) {
        setState(() => _initialFeePaidLocal = true);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                '初期費用はすでにお支払い済みです',
                style: TextStyle(fontFamily: 'LINEseed'),
              ),
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('初期費用リンクを取得できませんでした', style: TextStyle()),
            ),
          );
        }
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '初期費用の決済開始に失敗: $e',
            style: TextStyle(fontFamily: 'LINEseed'),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _creatingInitial = false);
    }
  }

  // ====== アクション：サブスク ======
  Future<void> _openSubscriptionCheckout() async {
    if (_creatingSub) return;
    setState(() => _creatingSub = true);
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
      final portalUrl = data['portalUrl'] as String?;
      final url = data['url'] as String?;
      final open = portalUrl ?? url;
      if (open != null) {
        await launchUrlString(
          open,
          mode: LaunchMode.platformDefault,
          webOnlyWindowName: '_blank',
        );
      } else {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('サブスクのリンクを取得できませんでした')));
        }
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('チェックアウト作成に失敗: $e')));
    } finally {
      if (mounted) setState(() => _creatingSub = false);
    }
  }

  // ====== アクション：Connect ======
  Future<void> _openConnectOnboarding() async {
    if (_creatingConnect || !_registered) return; // 本登録前は押せない
    setState(() => _creatingConnect = true);
    try {
      final caller = widget.functions.httpsCallable('upsertConnectedAccount');
      final payload = {
        'tenantId': widget.tenantId,
        'account': {
          'country': 'JP',
          'businessType': 'individual',
          'email': FirebaseAuth.instance.currentUser?.email,
          'businessProfile': {'product_description': 'チップ受け取り（チッププラットフォーム）'},
          'tosAccepted': true,
        },
      };
      final res = await caller.call(payload);
      final data = (res.data as Map?) ?? {};
      final onboardingUrl = data['onboardingUrl'] as String?;
      if (onboardingUrl != null && onboardingUrl.isNotEmpty) {
        await launchUrlString(
          onboardingUrl,
          mode: LaunchMode.platformDefault,
          webOnlyWindowName: '_blank',
        );
      } else {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Stripe接続が更新されました')));
        }
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Stripe接続の開始に失敗: $e',
            style: TextStyle(fontFamily: 'LINEseed'),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _creatingConnect = false);
    }
  }

  Future<void> _checkConnectLatest() async {
    if (_checkingConnect) return;
    setState(() => _checkingConnect = true);
    try {
      final doc = await FirebaseFirestore.instance
          .collection(uid)
          .doc(widget.tenantId)
          .get();
      final c = (doc.data()?['connect'] as Map?) ?? {};
      final ok =
          (c['charges_enabled'] == true) && (c['payouts_enabled'] == true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ok ? '接続は有効です' : 'まだ提出が必要です',
            style: TextStyle(fontFamily: 'LINEseed'),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '状態の取得に失敗: $e',
            style: TextStyle(fontFamily: 'LINEseed'),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _checkingConnect = false);
    }
  }

  // ====== 保存：下書き ======
  Future<void> _saveDraft() async {
    if (_savingDraft || uid.isEmpty) return;
    setState(() => _savingDraft = true);
    try {
      final ref = FirebaseFirestore.instance
          .collection(uid)
          .doc(widget.tenantId);
      await ref.set({
        'name': widget.tenantName,
        'members': [uid],
        'status': 'nonactive',
        'createdBy': {
          'uid': uid,
          'email': FirebaseAuth.instance.currentUser?.email,
        },
        'updatedAt': FieldValue.serverTimestamp(),
        'createdAt': FieldValue.serverTimestamp(), // merge時は初回のみ実質更新
      }, SetOptions(merge: true));

      setState(() => _hasDraft = true);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('下書きを保存しました', style: TextStyle(fontFamily: 'LINEseed')),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '下書き保存に失敗: $e',
            style: TextStyle(fontFamily: 'LINEseed'),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _savingDraft = false);
    }
  }

  // ====== 保存：本登録（サブスク完了後に有効） ======
  Future<void> _saveFinalRegistration() async {
    if (_savingFinal || !_subscribedLocal || _registered || uid.isEmpty) return;
    setState(() => _savingFinal = true);
    try {
      final ref = FirebaseFirestore.instance
          .collection(uid)
          .doc(widget.tenantId);
      final data = <String, dynamic>{
        'name': widget.tenantName,
        'members': [uid],
        'status': 'active',
        'createdAt': FieldValue.serverTimestamp(),
        'createdBy': {
          'uid': uid,
          'email': FirebaseAuth.instance.currentUser?.email,
        },

        'updatedAt': FieldValue.serverTimestamp(),
      };
      await ref.set(data, SetOptions(merge: true));

      if (!mounted) return;
      setState(() {
        _registered = true;
        _hasDraft = false; // 本登録したので“下書き”状態は解除
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'アカウント登録ありがとうございます！コネクトアカウントとメンバー追加を進めましょう。',
            style: TextStyle(fontFamily: 'LINEseed'),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('本登録に失敗: $e', style: TextStyle(fontFamily: 'LINEseed')),
        ),
      );
    } finally {
      if (mounted) setState(() => _savingFinal = false);
    }
  }

  // 下書き破棄（任意）
  Future<void> _discardDraft() async {
    if (uid.isEmpty) return;
    try {
      await FirebaseFirestore.instance
          .collection(uid)
          .doc(widget.tenantId)
          .delete();
      if (!mounted) return;
      setState(() {
        _hasDraft = false;
        _initialFeePaidLocal = false;
        _subscribedLocal = false;
        selectedPlan = "A";
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('下書きを破棄しました', style: TextStyle(fontFamily: 'LINEseed')),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '下書きの破棄に失敗: $e',
            style: TextStyle(fontFamily: 'LINEseed'),
          ),
        ),
      );
    }
  }

  // ====== UI ======
  @override
  Widget build(BuildContext context) {
    // tenants/{id} が存在すれば購読（Webhook反映を自動で拾う）
    final tenantStream = FirebaseFirestore.instance
        .collection(uid)
        .doc(widget.tenantId)
        .snapshots();

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: tenantStream,
      builder: (context, snap) {
        final m = snap.data?.data() ?? {};
        final billing = (m['billing'] as Map?) ?? {};
        final initialFeeFromFs =
            ((billing['initialFee'] as Map?) ?? {})['status'] == 'paid';
        final sub = (m['subscription'] as Map?) ?? {};
        final subStatus = (sub['status'] as String? ?? '').toLowerCase();
        final subscribedFromFs =
            (subStatus == 'active' || subStatus == 'trialing');
        final connect = (m['connect'] as Map?) ?? {};
        final chargesEnabled = connect['charges_enabled'] == true;
        final payoutsEnabled = connect['payouts_enabled'] == true;
        final connectOk = chargesEnabled && payoutsEnabled;

        // 表示上の完了判定（Firestore or ローカルイベント or 下書き反映）
        final initialFeePaid = initialFeeFromFs || _initialFeePaidLocal;
        final subscribed = subscribedFromFs || _subscribedLocal;

        // tenants が出来ていれば「登録済み」とみなす
        _registered = _registered || (snap.data?.exists == true);

        // ステップ誘導
        int desiredStep = step;
        if (desiredStep == 0 && initialFeePaid) desiredStep = 1;
        if (desiredStep <= 1 && subscribed) desiredStep = 2;
        if (desiredStep <= 2 && connectOk) desiredStep = 3;
        if (desiredStep != step) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => step = desiredStep);
          });
        }

        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
                  '新規店舗作成',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Colors.black87,
                    fontFamily: 'LINEseed',
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  widget.tenantName,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Colors.black54,
                    fontFamily: 'LINEseed',
                  ),
                ),
                const SizedBox(height: 12),

                // === 下書きバナー（続きから再開） ===
                if (_hasDraft && !_registered)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF9F9F9),
                      border: Border.all(color: Colors.black12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.restart_alt, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '下書きが見つかりました。前回の続きから再開できます'
                            '${_draftUpdatedAt != null ? '（最終更新: ${_draftUpdatedAt!}）' : ''}。',
                            style: const TextStyle(
                              fontSize: 13,
                              fontFamily: 'LINEseed',
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton(
                          onPressed: _loadDraft, // 念のため最新を再読込
                          child: const Text(
                            '再開',
                            style: TextStyle(fontFamily: 'LINEseed'),
                          ),
                        ),
                        const SizedBox(width: 6),
                        TextButton(
                          onPressed: _discardDraft,
                          child: const Text(
                            '下書きを破棄',
                            style: TextStyle(fontFamily: 'LINEseed'),
                          ),
                        ),
                      ],
                    ),
                  ),

                // ==== 3ボタンを同一モーダルで並べる ====
                _actionCard(
                  title: '初期費用',
                  description: 'まずは初期費用のお支払いをお願いします。',
                  trailing: _statusPill(initialFeePaid),
                  child: FilledButton.icon(
                    onPressed: (initialFeePaid || _creatingInitial)
                        ? null
                        : _openInitialFeeCheckout,
                    icon: _creatingInitial
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.open_in_new),
                    label: Text(
                      initialFeePaid ? '支払い済み' : '初期費用を支払う',
                      style: TextStyle(fontFamily: 'LINEseed'),
                    ),
                  ),
                ),

                const SizedBox(height: 10),
                _actionCard(
                  title: 'サブスク登録',
                  description: 'プランを選択し、登録へ進んでください。',
                  trailing: _statusPill(subscribed),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _planChips(),
                      const SizedBox(height: 8),
                      FilledButton.icon(
                        onPressed: (subscribed || _creatingSub)
                            ? null
                            : _openSubscriptionCheckout,
                        icon: _creatingSub
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.open_in_new),
                        label: Text(
                          subscribed ? '登録済み' : 'サブスク登録へ進む',
                          style: TextStyle(fontFamily: 'LINEseed'),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 10),
                _actionCard(
                  title: 'Stripe Connect',
                  description: '売上受け取り用のコネクトアカウントを作成します（本人確認・口座登録）。',
                  trailing: _statusPill(chargesEnabled && payoutsEnabled),
                  child: Row(
                    children: [
                      Expanded(
                        child: Tooltip(
                          message: _registered
                              ? ((chargesEnabled && payoutsEnabled)
                                    ? '接続済み'
                                    : '')
                              : 'まず「本登録を保存」でアカウント作成を完了してください',
                          child: FilledButton.icon(
                            onPressed:
                                (!_registered ||
                                    (chargesEnabled && payoutsEnabled) ||
                                    _creatingConnect)
                                ? null
                                : _openConnectOnboarding,
                            icon: _creatingConnect
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.login),
                            label: Text(
                              (chargesEnabled && payoutsEnabled)
                                  ? '接続済み'
                                  : 'Stripe接続に進む',
                              style: TextStyle(fontFamily: 'LINEseed'),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      OutlinedButton.icon(
                        onPressed: (!_registered || _checkingConnect)
                            ? null
                            : _checkConnectLatest,
                        icon: _checkingConnect
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.sync),
                        label: const Text(
                          '接続状態を確認',
                          style: TextStyle(fontFamily: 'LINEseed'),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 18),

                // ==== 下部アクション（保存ボタン） ====
                Row(
                  children: [
                    if (_registered)
                      OutlinedButton.icon(
                        onPressed: () async {
                          Navigator.of(context).pop(); // ② モーダルを閉じる
                        },

                        label: const Text(
                          '戻る',
                          style: TextStyle(fontFamily: 'LINEseed'),
                        ),
                      ),
                    if (!_registered)
                      OutlinedButton.icon(
                        onPressed: _savingDraft
                            ? null
                            : () async {
                                await _saveDraft(); // ① 下書き保存（進捗とplanも保存）
                                if (!mounted) return;
                                Navigator.of(
                                  context,
                                  rootNavigator: true,
                                ).pop('draftSaved'); // ② モーダルを閉じる
                              },
                        icon: _savingDraft
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.save_outlined),
                        label: const Text(
                          '下書き保存',
                          style: TextStyle(fontFamily: 'LINEseed'),
                        ),
                      ),

                    const Spacer(),
                    FilledButton.icon(
                      onPressed:
                          (!_subscribedLocal || _savingFinal || _registered)
                          ? null
                          : _saveFinalRegistration,
                      icon: _savingFinal
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.check_circle),
                      label: Text(
                        _registered ? '登録済み' : '本登録を保存',
                        style: TextStyle(fontFamily: 'LINEseed'),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 8),
                if (!_subscribedLocal)
                  const Text(
                    '※「本登録を保存」はサブスク登録が完了すると有効になります。',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.black54,
                      fontFamily: 'LINEseed',
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ===== パーツ =====
  Widget _actionCard({
    required String title,
    required String description,
    required Widget child,
    Widget? trailing,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.black12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  color: Colors.black87,
                  fontFamily: 'LINEseed',
                ),
              ),
              const Spacer(),
              if (trailing != null) trailing,
            ],
          ),
          const SizedBox(height: 6),
          Text(
            description,
            style: const TextStyle(
              color: Colors.black87,
              fontFamily: 'LINEseed',
            ),
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }

  Widget _statusPill(bool done) {
    final c = done ? Colors.green : Colors.black26;
    final icon = done ? Icons.check_circle : Icons.radio_button_unchecked;
    final label = done ? '完了' : '未完了';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: done ? c.withOpacity(.1) : Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: c),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: c),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: c,
              fontWeight: FontWeight.w700,
              fontFamily: 'LINEseed',
            ),
          ),
        ],
      ),
    );
  }

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
                            fontFamily: 'LINEseed',
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
                            fontFamily: 'LINEseed',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        p.monthly == 0 ? '無料' : '¥${p.monthly}/月',
                        style: TextStyle(
                          color: fg,
                          fontWeight: FontWeight.w700,
                          fontFamily: 'LINEseed',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '手数料 ${p.feePct}%',
                    style: TextStyle(
                      color: fg.withOpacity(.8),
                      fontFamily: 'LINEseed',
                    ),
                  ),
                  const SizedBox(height: 6),
                  ...p.features.map(
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
                              style: TextStyle(
                                color: fg,
                                height: 1.2,
                                fontFamily: 'LINEseed',
                              ),
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
}

// ===== サポート =====
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
