import 'dart:async';
import 'dart:html' as html;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:flutter/services.dart';

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
  TextEditingController tenantNameEdit = TextEditingController();

  // UIフラグ
  bool _creatingInitial = false;
  bool _creatingSub = false;
  bool _creatingConnect = false;
  bool _checkingConnect = false;
  bool _savingDraft = false;
  bool _savingFinal = false;
  bool _registered = false;
  String tenantName = "";

  // 下書き関連
  bool _hasDraft = false;
  DateTime? _draftUpdatedAt;

  // ---- 追加：リアルタイム連携（他タブ通知／フォーカス復帰） ----
  html.BroadcastChannel? _bc;
  StreamSubscription<html.MessageEvent>? _postMessageSub;
  StreamSubscription<html.Event>? _focusSub;

  // ---- 追加：ドラフト監視（uid/{tenantId} の変化も即反映）----
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _draftSub;
  bool _openingConnectPortal = false;

  late final String uid;

  @override
  void initState() {
    super.initState();
    uid = FirebaseAuth.instance.currentUser?.uid ?? '';

    _setupRealtimeBridges(); // ← 追加：決済完了通知＆フォーカス復帰で再取得
    _subscribeDraftChanges(); // ← 追加：ドラフトの変更も画面に反映
    tenantName = widget.tenantName;
    _loadDraft(); // 既存下書きの反映
  }

  @override
  void dispose() {
    _bc?.close();
    _postMessageSub?.cancel();
    _focusSub?.cancel();
    _draftSub?.cancel();
    super.dispose();
  }

  /// Stripe requirements のキーを日本語にざっくりマッピング
  String _labelForRequirement(String key) {
    // よく出るキーを人間語に
    const map = {
      'individual.verification.document': '本人確認書類（個人）',
      'individual.verification.additional_document': '本人確認の追加書類（個人）',
      'individual.id_number': '個人番号（マイナンバーではなく本人確認用ID）',
      'individual.email': '個人のメールアドレス',
      'individual.phone': '個人の電話番号',
      'company.verification.document': '事業者の証明書類（登記/証明 等）',
      'company.representative.verification.document': '代表者の本人確認書類',
      'external_account': '入金用の銀行口座登録',
      'business_profile.url': '事業のウェブサイトURL',
      'business_profile.mcc': '事業カテゴリ（MCC）',
      'tos_acceptance.ip': '利用規約（TOS）の同意',
    };

    if (map.containsKey(key)) return map[key]!;
    // ドット区切りをそれっぽく整形
    final parts = key.split('.');
    final tail = parts.isNotEmpty ? parts.last : key;
    return tail
        .replaceAll('_', ' ')
        .replaceAll('-', ' ')
        .replaceFirstMapped(RegExp(r'^[a-z]'), (m) => m[0]!.toUpperCase());
  }

  Future<void> _showRequirementsDialog({
    required List<String> currentlyDue,
    required List<String> pastDue,
    required List<String> pendingVerification,
    required List errorsRaw,
    required bool isPendingVerification,
  }) async {
    // エラー文字列を安全に抽出
    List<Widget> _errorTiles() {
      if (errorsRaw.isEmpty) return [];
      return errorsRaw.map<Widget>((e) {
        try {
          final m = (e as Map).cast<String, dynamic>();
          final reqKey = (m['requirement'] ?? '') as String;
          final reason = (m['reason'] ?? m['code'] ?? m['message'] ?? '')
              .toString();
          final label = reqKey.isNotEmpty ? _labelForRequirement(reqKey) : '不明';
          return _reqTile(
            label,
            reason: reason,
            icon: Icons.error,
            color: Colors.redAccent,
          );
        } catch (_) {
          return _reqTile(
            e.toString(),
            icon: Icons.error,
            color: Colors.redAccent,
          );
        }
      }).toList();
    }

    await showDialog(
      context: context,
      builder: (_) {
        return AlertDialog(
          title: const Text('提出状況の確認'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (currentlyDue.isNotEmpty) ...[
                    _sectionHeader('提出が必要な項目'),
                    ...currentlyDue.map(
                      (k) => _reqTile(
                        _labelForRequirement(k),
                        icon: Icons.assignment_late,
                        color: Colors.orange,
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (pastDue.isNotEmpty) ...[
                    _sectionHeader('期限切れ（再提出が必要）'),
                    ...pastDue.map(
                      (k) => _reqTile(
                        _labelForRequirement(k),
                        icon: Icons.report,
                        color: Colors.redAccent,
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (isPendingVerification) ...[
                    _sectionHeader('審査中の項目'),
                    if (pendingVerification.isNotEmpty)
                      ...pendingVerification.map(
                        (k) => _reqTile(
                          _labelForRequirement(k),
                          icon: Icons.hourglass_top,
                          color: Colors.blueGrey,
                        ),
                      ),
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text('Stripe が提出済みの書類を確認しています。完了までお待ちください。'),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (errorsRaw.isNotEmpty) ...[
                    _sectionHeader('エラー（再提出の必要あり）'),
                    ..._errorTiles(),
                  ],
                  if (currentlyDue.isEmpty &&
                      pastDue.isEmpty &&
                      !isPendingVerification &&
                      errorsRaw.isEmpty)
                    const Text('現在、提出すべき不足や審査中の項目は見つかりませんでした。'),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('閉じる'),
            ),
            FilledButton.icon(
              onPressed: () {
                Navigator.pop(context);
                _openConnectPortal();
              },
              icon: const Icon(Icons.open_in_new),
              label: const Text('コネクトポータルを開く'),
            ),
          ],
        );
      },
    );
  }

  // ダイアログ用の小パーツ
  Widget _sectionHeader(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(text, style: const TextStyle(fontWeight: FontWeight.w700)),
  );

  Widget _reqTile(
    String label, {
    IconData? icon,
    Color? color,
    String? reason,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon ?? Icons.info_outline,
            size: 18,
            color: color ?? Colors.black54,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label),
                if (reason != null && reason.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      reason,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.black54,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openConnectPortal() async {
    if (_creatingConnect) return;
    setState(() => _creatingConnect = true);
    try {
      final res = await widget.functions
          .httpsCallable('createConnectAccountLink')
          .call({'tenantId': widget.tenantId});
      final data = (res.data as Map?) ?? {};
      final url = data['url'] as String?;
      if (url != null && url.isNotEmpty) {
        await launchUrlString(
          url,
          mode: LaunchMode.platformDefault,
          webOnlyWindowName: '_blank',
        );
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('コネクトポータルのリンクを取得できませんでした')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('ポータル起動に失敗: $e')));
    } finally {
      if (mounted) setState(() => _creatingConnect = false);
    }
  }

  String _humanizeRequirementKey(String key) {
    // 代表例だけ人間語に。未知キーはそのまま返す
    switch (key) {
      case 'individual.verification.document':
        return '本人確認書類の確認';
      case 'external_account':
        return '入金用銀行口座の登録/確認';
      case 'company.verification.document':
        return '法人の確認書類';
      case 'business_profile.mcc':
        return '業種の設定（MCC）';
      case 'business_profile.product_description':
        return '事業内容の説明';
      case 'tos_acceptance.date':
      case 'tos_acceptance.ip':
        return '利用規約への同意';
      default:
        return key; // fallback
    }
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
      if (status == "active") {
        setState(() {
          _registered = true;
        });
      }
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
            'name': tenantName,
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
            'name': widget.tenantName,
          });
      final data = res.data as Map;
      final portalUrl = data['portalUrl'] as String?;
      final url = data['url'] as String?;
      final open = portalUrl ?? url;
      if (open != null) {
        await launchUrlString(
          open,
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
        "payoutSchedule": {
          "monthly": 'weekly',

          "monthlyAnchor": 1,
          "delayDays": 'minimum',
        },
      };
      final res = await caller.call(payload);
      final data = (res.data as Map?) ?? {};
      final onboardingUrl = data['onboardingUrl'] as String?;
      if (onboardingUrl != null && onboardingUrl.isNotEmpty) {
        await launchUrlString(
          onboardingUrl,
          mode: LaunchMode.platformDefault,
          webOnlyWindowName: '_self',
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

  Future<void> _maybeLinkAgencyFromTenantDoc({
    required String ownerUid,
    required DocumentReference<Map<String, dynamic>> tenantRef,
    required String tenantName,
    required String desiredStatus, // 'draft' | 'active'
    required BuildContext scaffoldContext,
  }) async {
    // 最新を読む
    final snap = await tenantRef.get();
    final m = (snap.data() ?? <String, dynamic>{});
    Map<String, dynamic> agency =
        (m['agency'] as Map?)?.cast<String, dynamic>() ?? {};

    String? agentId = agency['agentId'] as String?;
    final code = (agency['code'] ?? '').toString();
    final linked = agency['linked'] == true;

    // code があるのに未リンクなら、リンクを試みる
    if (agentId == null && code.isNotEmpty && !linked) {
      final linkedInfo = await _tryLinkAgencyByCodeInternal(
        code: code,
        tenantRef: tenantRef,
        tenantName: tenantName,
        ownerUid: ownerUid,
      );
      if (linkedInfo != null) {
        agentId = linkedInfo.agentId;
        agency = {
          ...agency,
          'agentId': linkedInfo.agentId,
          'commissionPercent': linkedInfo.commissionPercent,
          'linked': true,
          'linkedAt': FieldValue.serverTimestamp(),
        };
        await tenantRef.set({
          'agency': agency,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        // index も鏡写し
        await FirebaseFirestore.instance
            .collection('tenantIndex')
            .doc(tenantRef.id)
            .set({
              'agency': agency,
              'updatedAt': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));
        ScaffoldMessenger.of(
          scaffoldContext,
        ).showSnackBar(SnackBar(content: Text('代理店とリンクしました（code: $code）')));
      }
    }

    // agentId が確定していれば contracts を desiredStatus でUpsert
    if (agentId != null && agentId.isNotEmpty) {
      await FirebaseFirestore.instance
          .collection('agencies')
          .doc(agentId)
          .collection('contracts')
          .doc(tenantRef.id)
          .set({
            'tenantId': tenantRef.id,
            'tenantName': tenantName,
            'ownerUid': ownerUid,
            'contractedAt': FieldValue.serverTimestamp(), // 初回作成で付与
            'updatedAt': FieldValue.serverTimestamp(),
            'status': desiredStatus, // 'draft' or 'active'
            if (desiredStatus == 'active')
              'activatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
    }
  }

  // ====== 保存：下書き ======
  Future<void> _saveDraft() async {
    if (_savingDraft || uid.isEmpty) return;
    setState(() => _savingDraft = true);
    try {
      final userRef = FirebaseFirestore.instance
          .collection(uid)
          .doc(widget.tenantId);
      final indexRef = FirebaseFirestore.instance
          .collection('tenantIndex')
          .doc(widget.tenantId);

      // 既存の agency 情報を拾っておく（code/agentId/linked など）
      final baseSnap = await userRef.get();
      final base = (baseSnap.data() ?? <String, dynamic>{});
      final agency = (base['agency'] as Map?)?.cast<String, dynamic>() ?? {};

      final data = {
        'members': [uid],
        'status': 'nonactive',
        'createdBy': {
          'uid': uid,
          'email': FirebaseAuth.instance.currentUser?.email,
        },
        'updatedAt': FieldValue.serverTimestamp(),
        'createdAt': FieldValue.serverTimestamp(), // merge時は初回のみ効く
        if (agency.isNotEmpty) 'agency': agency, // インデックスにも鏡写し
      };

      // 本体とインデックスを同時に更新
      await Future.wait([
        userRef.set(data, SetOptions(merge: true)),
        indexRef.set({
          ...data,
          'uid': uid, // インデックスにはオーナーuidも持たせる
        }, SetOptions(merge: true)),
      ]);

      // 代理店コードがあればリンクを試み、contracts を draft で作成/更新
      await _maybeLinkAgencyFromTenantDoc(
        ownerUid: uid,
        tenantRef: userRef,
        tenantName: tenantNameEdit.text,
        desiredStatus: 'draft',
        scaffoldContext: context,
      );

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
            style: const TextStyle(fontFamily: 'LINEseed'),
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
      final userRef = FirebaseFirestore.instance
          .collection(uid)
          .doc(widget.tenantId);
      final indexRef = FirebaseFirestore.instance
          .collection('tenantIndex')
          .doc(widget.tenantId);

      // 既存の agency を拾って index にも反映
      final baseSnap = await userRef.get();
      final base = (baseSnap.data() ?? <String, dynamic>{});
      final agency = (base['agency'] as Map?)?.cast<String, dynamic>() ?? {};

      final data = <String, dynamic>{
        'members': [uid],
        'status': 'active',
        'createdAt': FieldValue.serverTimestamp(),
        'createdBy': {
          'uid': uid,
          'email': FirebaseAuth.instance.currentUser?.email,
        },
        'updatedAt': FieldValue.serverTimestamp(),
        if (agency.isNotEmpty) 'agency': agency,
        'activatedAt': FieldValue.serverTimestamp(),
      };

      // 1) 本登録を本体 & インデックスに保存
      await Future.wait([
        userRef.set(data, SetOptions(merge: true)),
        indexRef.set({
          ...data,
          'uid': uid, // インデックスにもオーナーuid
        }, SetOptions(merge: true)),
      ]);

      // 2) 代理店連携（あれば）を active に更新
      await _maybeLinkAgencyFromTenantDoc(
        ownerUid: uid,
        tenantRef: userRef,
        tenantName: tenantNameEdit.text,
        desiredStatus: 'active',
        scaffoldContext: context,
      );

      if (!mounted) return;

      // 3) 初回だけ“今日から”の店舗控除入力→ 両方に保存されるよう関数内で対応（既存）
      await _promptInitialStoreDeduction(userRef);

      // 4) UI更新
      setState(() {
        _registered = true;
        _hasDraft = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'アカウント登録ありがとうございます！',
            style: TextStyle(fontFamily: 'LINEseed'),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '本登録に失敗: $e',
            style: const TextStyle(fontFamily: 'LINEseed'),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _savingFinal = false);
    }
  }

  /// 登録完了時だけ見せる控除入力ダイアログ（％と固定額）
  /// 保存した場合のみ storeDeductionPending に「今日から」適用で保存します。
  Future<void> _promptInitialStoreDeduction(
    DocumentReference<Map<String, dynamic>> tenantRef,
  ) async {
    final percentCtrl = TextEditingController(text: '');
    final fixedCtrl = TextEditingController(text: '');
    bool saving = false;

    // 入力→正規化
    double _parsePercent(String s) {
      final v = double.tryParse(s.replaceAll('％', '').trim()) ?? 0.0;
      if (v.isNaN) return 0.0;
      return v.clamp(0.0, 100.0);
    }

    int _parseFixed(String s) {
      final v = int.tryParse(s.replaceAll(RegExp(r'[^0-9]'), '').trim()) ?? 0;
      return v < 0 ? 0 : v;
    }

    await showDialog<bool>(
      context: context,
      barrierDismissible: false, // タップで勝手に閉じない
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            final enableSave = !saving; // 初期は保存可（入力は任意）

            return AlertDialog(
              backgroundColor: Colors.white,
              surfaceTintColor: Colors.transparent,
              title: const Text(
                '店舗が差し引く金額を設定',
                style: TextStyle(color: Colors.black87, fontFamily: 'LINEseed'),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '※ 登録直後のこのタイミングのみ、本日からの適用で保存できます。\n　（あとで変更する場合は翌月からの適用になります）',
                      style: TextStyle(
                        color: Colors.black54,
                        fontSize: 12,
                        fontFamily: 'LINEseed',
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: percentCtrl,
                    decoration: const InputDecoration(
                      labelText: '差し引く割合（％）',
                      hintText: '例: 10 または 12.5',
                      suffixText: '%',
                    ),
                    keyboardType: const TextInputType.numberWithOptions(
                      signed: false,
                      decimal: true,
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: saving ? null : () => Navigator.pop(ctx, false),
                  child: const Text(
                    'あとで',
                    style: TextStyle(
                      color: Colors.black87,
                      fontFamily: 'LINEseed',
                    ),
                  ),
                ),
                FilledButton.icon(
                  onPressed: !enableSave
                      ? null
                      : () async {
                          setLocal(() => saving = true);
                          try {
                            final p = _parsePercent(percentCtrl.text);
                            final f = _parseFixed(fixedCtrl.text);

                            final eff = DateTime.now(); // ← この時だけ “今日から” 適用
                            await tenantRef.set({
                              'storeDeduction': {'percent': p, 'fixed': f},
                            }, SetOptions(merge: true));

                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    '店舗控除を保存しました（本日 ${eff.hour.toString().padLeft(2, '0')}:${eff.minute.toString().padLeft(2, '0')} から適用）',
                                    style: const TextStyle(
                                      fontFamily: 'LINEseed',
                                    ),
                                  ),
                                ),
                              );
                            }
                            if (ctx.mounted) Navigator.pop(ctx, true);
                          } catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('保存に失敗: $e')),
                              );
                            }
                            setLocal(() => saving = false);
                          }
                        },
                  icon: saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.save),
                  label: const Text('保存'),
                ),
              ],
            );
          },
        );
      },
    );

    percentCtrl.dispose();
    fixedCtrl.dispose();
  }

  // ====== UI ======
  @override
  Widget build(BuildContext context) {
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

        // requirements を読み出し
        final req = (connect['requirements'] as Map?) ?? {};
        final currentlyDue =
            (req['currently_due'] as List?)?.cast<String>() ?? [];
        final pastDue = (req['past_due'] as List?)?.cast<String>() ?? [];
        final pendingVerification =
            (req['pending_verification'] as List?)?.cast<String>() ?? [];
        final disabledReason = (req['disabled_reason'] as String?) ?? '';
        final errorsRaw = (req['errors'] as List?) ?? [];

        final needsSubmission = currentlyDue.isNotEmpty || pastDue.isNotEmpty;
        final isPendingVerification =
            disabledReason == 'requirements.pending_verification' ||
            pendingVerification.isNotEmpty;

        // 「申請前（未開始）」かどうか：requirements などが全く無い段階
        final hasConnectStarted =
            req.isNotEmpty || (connect['details_submitted'] == true);

        // 画面に出す不足キー（提出必要＆期限切れ）
        final pendingKeys = <String>[...currentlyDue, ...pastDue];
        final bool disabled = _creatingConnect || !_registered;

        // 表示上の完了判定（Firestore or ローカルイベント or 下書き反映）
        final initialFeePaid = initialFeeFromFs || _initialFeePaidLocal;
        final subscribed = subscribedFromFs || _subscribedLocal;
        final trial = (sub["trial"] as Map?) ?? {};
        final trialStatus;
        if (trial.isNotEmpty) {
          trialStatus = trial["status"] as String ?? "";
        } else {
          trialStatus = "";
        }

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
                  '新規店舗作成\nサポート費用、サブスクリプションの登録、コネクトアカウントの登録を完了し、チップを受け取る準備を完了しましょう。',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Colors.black87,
                    fontFamily: 'LINEseed',
                  ),
                ),

                const SizedBox(height: 12),

                // ==== 3ボタンを同一モーダルで並べる ====
                _actionCard(
                  title: 'サポート料金(初回のみ)',
                  description: '初回限定で9800円でポスターの手配等、1か月間のサポートを行います。',
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
                      initialFeePaid ? '支払い済み' : 'サポート料金を支払う',
                      style: TextStyle(fontFamily: 'LINEseed'),
                    ),
                  ),
                ),

                const SizedBox(height: 10),

                _actionCard(
                  title: 'サブスクリプション登録',
                  description: 'プランを選択し、登録へ進んでください',
                  trailing: _statusPill(subscribed),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      trialStatus == "none"
                          ? Text("")
                          : Text.rich(
                              TextSpan(
                                style: const TextStyle(fontFamily: 'LINEseed'),
                                children: const [
                                  TextSpan(text: '始めの3ヶ月はトライアル期間により、'),
                                  TextSpan(
                                    text: '無料',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: Colors.red,
                                    ),
                                  ),
                                  TextSpan(text: 'で使用することができます。'),
                                ],
                              ),
                            ),

                      _planChips(trialStatus),
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
                      const SizedBox(height: 5),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Expanded(
                            child: Text(
                              "※stripeの振込手数料＋決済手数料（元金の3.6%）が差し引かれます。",
                              style: TextStyle(fontSize: 10),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 10),
                _actionCard(
                  title: 'Stripe Connect',
                  description: '売上受け取り用のコネクトアカウントを作成します（本人確認・口座登録）',
                  trailing: _statusPill(connectOk),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // --- ボタン出し分け（どちらか一方 or 完了で非表示） ---
                      Row(
                        children: [
                          Expanded(
                            child: () {
                              // 0) 申請前（未開始）→ Hosted Onboarding
                              if (!hasConnectStarted) {
                                return _creatingConnect
                                    ? const Center(
                                        child: SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        ),
                                      )
                                    : FilledButton.icon(
                                        onPressed: disabled
                                            ? null
                                            : _openConnectOnboarding,
                                        icon: _creatingConnect
                                            ? const SizedBox(
                                                width: 18,
                                                height: 18,
                                                child:
                                                    CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                    ),
                                              )
                                            : const Icon(Icons.login),
                                        label: Text(
                                          _creatingConnect
                                              ? '処理中…'
                                              : 'Stripe接続に進む',
                                        ),
                                        style: FilledButton.styleFrom(
                                          // 無効時の見た目（必要に応じて調整）
                                          disabledBackgroundColor:
                                              Colors.black12,
                                          disabledForegroundColor:
                                              Colors.black45,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 12,
                                          ),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                          ),
                                        ),
                                      );
                              }

                              // 1) 申請後〜完了前 → コネクトポータル
                              if (!connectOk) {
                                return OutlinedButton.icon(
                                  onPressed: _openingConnectPortal
                                      ? null
                                      : _openConnectPortal,
                                  icon: _openingConnectPortal
                                      ? const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Icon(Icons.open_in_new),
                                  label: const Text('コネクトポータルを開く'),
                                );
                              }

                              // 2) 完了 → ボタン無し
                              return const SizedBox.shrink();
                            }(),
                          ),

                          if (hasConnectStarted && !connectOk)
                            const SizedBox(width: 10),

                          // 「不足項目を確認」：申請開始済みで未完了のときだけ出す
                          if (hasConnectStarted && !connectOk)
                            OutlinedButton(
                              onPressed: () => _showRequirementsDialog(
                                currentlyDue: currentlyDue,
                                pastDue: pastDue,
                                pendingVerification: pendingVerification,
                                errorsRaw: errorsRaw,
                                isPendingVerification: isPendingVerification,
                              ),
                              child: const Text('不足項目を再提出'),
                            ),
                        ],
                      ),
                      Text.rich(
                        TextSpan(
                          style: const TextStyle(fontFamily: 'LINEseed'),
                          children: const [
                            TextSpan(text: 'こちらに登録いただいた口座へ'),
                            TextSpan(
                              text: '毎月1日',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.red,
                              ),
                            ),
                            TextSpan(text: 'にチップが振り込まれます。'),
                          ],
                        ),
                      ),

                      // 申請前は説明だけ、申請後は軽いヒントだけ（詳細はダイアログへ）
                      if (!hasConnectStarted) ...[
                        const SizedBox(height: 8),
                        const Text(
                          'Stripe 接続を開始して、本人確認と入金口座の登録を進めてください。',
                          style: TextStyle(color: Colors.black54, fontSize: 12),
                        ),
                      ] else if (!connectOk) ...[
                        const SizedBox(height: 8),
                        const Text(
                          '不足や審査状況は「不足項目を確認」から詳細をご確認ください。',
                          style: TextStyle(color: Colors.black54, fontSize: 12),
                        ),
                      ],
                      // 完了なら何も出さない
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

  Widget _planChips(String trialStatus) {
    const plans = <_Plan>[
      _Plan(
        code: 'A',
        title: 'Aプラン',
        monthly: 1980,
        feePct: 35,
        features: ['月額1980円で手軽に今すぐ開始'],
      ),
      _Plan(
        code: 'B',
        title: 'Bプラン',
        monthly: 7960,
        feePct: 25,
        features: ['公式ライン案内', "チップとともにコメントの送信"],
      ),
      _Plan(
        code: 'C',
        title: 'Cプラン',
        monthly: 19600,
        feePct: 15,
        features: [
          '公式ライン案内',
          "チップとともにコメントの送信",
          'Googleレビュー導線の設置',
          "オリジナルポスター作成",
          "お客様への感謝動画",
        ],
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
                      // B/C は「定価に取り消し線 + 無料」、それ以外（A）は従来どおり
                      ((p.code == "A" || p.code == 'B' || p.code == 'C') &&
                              trialStatus != "none")
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // 定価（取り消し線）
                                Text(
                                  '¥${p.monthly}/月',
                                  style: TextStyle(
                                    color: fg.withOpacity(.9),
                                    fontWeight: FontWeight.w700,
                                    fontFamily: 'LINEseed',
                                    decoration: TextDecoration.lineThrough,
                                    decorationThickness: 2,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                // 「無料」バッジ風
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: sel ? Colors.black : Colors.white,
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(color: fg, width: 1),
                                  ),
                                  child: Text(
                                    '無料',
                                    style: TextStyle(
                                      color: sel
                                          ? Colors.white
                                          : Colors.black87,
                                      fontWeight: FontWeight.w800,
                                      fontFamily: 'LINEseed',
                                    ),
                                  ),
                                ),
                              ],
                            )
                          : Text(
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
                    'チップ手数料 ${p.feePct}%',
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

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth > 600) {
          // PC表示 → 横並び
          return IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (int i = 0; i < plans.length; i++) ...[
                  Expanded(child: item(plans[i])),
                  if (i < plans.length - 1) const SizedBox(width: 10),
                ],
              ],
            ),
          );
        } else {
          // モバイル表示 → 縦並び
          return Column(children: plans.map((p) => item(p)).toList());
        }
      },
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

/// agencies を code で逆引きして agentId と commissionPercent を返す
class _AgentLink {
  final String agentId;
  final int commissionPercent;
  const _AgentLink(this.agentId, this.commissionPercent);
}

Future<_AgentLink?> _tryLinkAgencyByCodeInternal({
  required String code,
  required DocumentReference<Map<String, dynamic>> tenantRef,
  required String tenantName,
  required String ownerUid,
}) async {
  final qs = await FirebaseFirestore.instance
      .collection('agencies')
      .where('code', isEqualTo: code)
      .where('status', isEqualTo: 'active')
      .limit(1)
      .get();
  if (qs.docs.isEmpty) return null;
  final agent = qs.docs.first;
  final pct = (agent.data()['commissionPercent'] as num?)?.toInt() ?? 0;
  return _AgentLink(agent.id, pct);
}
