import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:yourpay/tenant/newTenant/onboardingSheet.dart';
// 1) 先頭の import に追加
import 'dart:math' as math;

class TenantSwitcherBar extends StatefulWidget {
  final String? currentTenantId;
  final String? currentTenantName;

  /// 従来のコールバック（後方互換のため残す）
  final void Function(String tenantId, String? tenantName) onChanged;

  /// ★拡張版：ownerUid と招待フラグも渡す（任意）
  ///   - 親が対応済みならこちらを呼びます
  ///   - 未設定なら従来の onChanged を呼びます
  final void Function(
    String tenantId,
    String? tenantName,
    String ownerUid,
    bool invited,
  )?
  onChangedEx;

  /// 余白（控えめにデフォルト調整）
  final EdgeInsetsGeometry padding;

  const TenantSwitcherBar({
    super.key,
    required this.onChanged,
    this.onChangedEx, // ★追加
    this.currentTenantId,
    this.currentTenantName,
    this.padding = const EdgeInsets.fromLTRB(10, 4, 10, 4),
  });

  @override
  State<TenantSwitcherBar> createState() => _TenantSwitcherBarState();
}

class _TenantSwitcherBarState extends State<TenantSwitcherBar> {
  final _functions = FirebaseFunctions.instanceFor(region: 'us-central1');

  String? _selectedId; // 旧：tenantId ベースの選択（互換用途）
  String? _selectedKey; // ★新：ownerUid/tenantId の複合キー
  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  // メモ化した参照
  late final CollectionReference<Map<String, dynamic>> _tenantCol;

  // 結合ストリーム（自分のテナント + 招待テナント）
  late final Stream<List<_TenantRow>> _combinedStream;
  late final StreamController<List<_TenantRow>> _combinedCtrl;
  final Map<String, StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>>
  _invitedDocSubs = {}; // key = "$ownerUid/$tenantId"
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _ownedSub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _invitedIndexSub;
  final Map<String, _TenantRow> _rows = {}; // key = "$ownerUid/$tenantId"

  // 複合キー
  String _keyOf(String ownerUid, String tenantId) => '$ownerUid/$tenantId';

  @override
  void initState() {
    super.initState();

    // 初期選択は props からのみ同期（親が決める・旧互換）
    _selectedId = widget.currentTenantId;

    // ユーザーが未ログインなら以降の処理は行わない（nullチェック）
    final uid = _uid;
    if (uid != null) {
      _tenantCol = FirebaseFirestore.instance.collection(uid);
      _combinedCtrl = StreamController<List<_TenantRow>>.broadcast();
      _combinedStream = _combinedCtrl.stream;

      void emit() {
        final list = _rows.values.toList()
          ..sort(
            (a, b) => (a.data['name'] ?? '').toString().toLowerCase().compareTo(
              (b.data['name'] ?? '').toString().toLowerCase(),
            ),
          );
        _combinedCtrl.add(list);
      }

      // (1) 自分のテナント
      _ownedSub = _tenantCol.snapshots().listen((qs) {
        // まず自分のキー領域を消してから追加
        _rows.removeWhere((k, _) => k.startsWith('$uid/'));
        for (final d in qs.docs) {
          final key = _keyOf(uid, d.id);
          _rows[key] = _TenantRow(
            ownerUid: uid,
            tenantId: d.id,
            data: d.data(),
            invited: false,
          );
        }
        emit();
      });

      // (2) 招待インデックス /<uid>/invited を購読し、各オーナー配下の実体をさらに購読
      final invitedRef = FirebaseFirestore.instance
          .collection(uid)
          .doc('invited');
      _invitedIndexSub = invitedRef.snapshots().listen((doc) {
        final map = (doc.data()?['tenants'] as Map<String, dynamic>?) ?? {};
        final should = <String>{};

        map.forEach((tenantId, v) {
          final ownerUid = (v is Map ? v['ownerUid'] : null)?.toString() ?? '';
          if (ownerUid.isEmpty) return;
          final key = _keyOf(ownerUid, tenantId as String);
          should.add(key);

          if (_invitedDocSubs.containsKey(key)) return;

          _invitedDocSubs[key] = FirebaseFirestore.instance
              .collection(ownerUid)
              .doc(tenantId)
              .snapshots()
              .listen((ds) {
                if (ds.exists) {
                  _rows[key] = _TenantRow(
                    ownerUid: ownerUid,
                    tenantId: ds.id,
                    data: ds.data() ?? {},
                    invited: ownerUid != uid,
                  );
                } else {
                  _rows.remove(key);
                }
                emit();
              });
        });

        // 不要になった購読を解除
        for (final key
            in _invitedDocSubs.keys
                .where((k) => !should.contains(k))
                .toList()) {
          _invitedDocSubs.remove(key)?.cancel();
          _rows.remove(key);
        }
        emit();
      });
    } else {
      _tenantCol = FirebaseFirestore.instance.collection('_');
      _combinedCtrl = StreamController<List<_TenantRow>>();
      _combinedStream = const Stream.empty();
    }
  }

  @override
  void dispose() {
    for (final s in _invitedDocSubs.values) {
      s.cancel();
    }
    _invitedDocSubs.clear();
    _ownedSub?.cancel();
    _invitedIndexSub?.cancel();
    try {
      _combinedCtrl.close();
    } catch (_) {}
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant TenantSwitcherBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 親が選択IDを更新したら、その値をそのまま反映（build中に通知はしない）
    if (oldWidget.currentTenantId != widget.currentTenantId) {
      _selectedId = widget.currentTenantId; // 旧互換：キー化は build 内で解決
      // _selectedKey は rows が出揃ってから同定する
    }
  }

  // ---- ここが肝：白×黒テーマ（ポップアップ用のローカルテーマ）----
  ThemeData bwTheme(BuildContext context) {
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

  Future<void> createTenantDialog() async {
    final nameCtrl = TextEditingController();
    final agentCtrl = TextEditingController(); // 代理店コード

    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black38,
      useRootNavigator: true,
      builder: (_) => Theme(
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
        child: WillPopScope(
          onWillPop: () async => false,
          child: AlertDialog(
            backgroundColor: const Color(0xFFF5F5F5),
            surfaceTintColor: Colors.transparent,
            titleTextStyle: const TextStyle(
              color: Colors.black87,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
            contentTextStyle: const TextStyle(
              color: Colors.black87,
              fontSize: 14,
            ),
            title: const Text(
              '新しい店舗を作成',
              style: TextStyle(fontFamily: 'LINEseed'),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  autofocus: true,
                  style: const TextStyle(color: Colors.black87),
                  decoration: const InputDecoration(
                    labelText: '店舗名',
                    hintText: '例）渋谷店',
                    labelStyle: TextStyle(color: Colors.black87),
                    hintStyle: TextStyle(color: Colors.black54),
                    filled: true,
                    fillColor: Colors.white,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: Colors.black26),
                      borderRadius: BorderRadius.all(Radius.circular(12)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: Colors.black87, width: 1.2),
                      borderRadius: BorderRadius.all(Radius.circular(12)),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                // 代理店コード入力（任意）
                TextField(
                  controller: agentCtrl,
                  style: const TextStyle(color: Colors.black87),
                  decoration: const InputDecoration(
                    labelText: '代理店コード（任意）',
                    hintText: '代理店の方からお聞きください',
                    labelStyle: TextStyle(color: Colors.black87),
                    hintStyle: TextStyle(color: Colors.black54),
                    filled: true,
                    fillColor: Colors.white,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: Colors.black26),
                      borderRadius: BorderRadius.all(Radius.circular(12)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: Colors.black87, width: 1.2),
                      borderRadius: BorderRadius.all(Radius.circular(12)),
                    ),
                  ),
                ),
              ],
            ),
            actionsPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 8,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                style: TextButton.styleFrom(foregroundColor: Colors.black87),
                child: const Text(
                  'キャンセル',
                  style: TextStyle(fontFamily: 'LINEseed'),
                ),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.black,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text(
                  '作成',
                  style: TextStyle(fontFamily: 'LINEseed'),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (ok != true) return;

    final name = nameCtrl.text.trim();
    final agentCode = agentCtrl.text.trim();
    if (name.isEmpty) return;

    // ❶ 代理店コードの事前チェック＆確認ダイアログ
    bool shouldTryLinkAgency = false;
    if (agentCode.isEmpty) {
      final proceed = await _confirmProceedWithoutAgency(
        context,
        title: '代理店コードが未入力です',
        message: '代理店と未連携のまま店舗を作成してよろしいですか？\n代理店の方から連携されている場合は、必ず入力ください',
        proceedLabel: '未連携で作成',
      );
      if (!proceed) return;
      shouldTryLinkAgency = false;
    } else {
      final exists = await _agencyCodeExists(agentCode);
      if (!exists) {
        final proceed = await _confirmProceedWithoutAgency(
          context,
          title: '代理店コードが見つかりません',
          message:
              '入力されたコード「$agentCode」は有効ではない可能性があります。\n'
              '代理店と未連携のまま店舗を作成してよろしいですか？',
          proceedLabel: '未連携で作成',
        );
        if (!proceed) return;
        shouldTryLinkAgency = false;
      } else {
        shouldTryLinkAgency = true;
      }
    }

    final uid = _uid; // 既存のログイン中ユーザーUID
    if (uid == null) return;

    final tenantsCol = FirebaseFirestore.instance.collection(uid);

    // ❷ 最初に「draft」で本体ドキュメントを作成（このIDを最後まで使う）
    final newRef = tenantsCol.doc(); // 自動ID
    final tenantId = newRef.id;

    final tenantIdDoc = FirebaseFirestore.instance
        .collection("tenantIndex")
        .doc(tenantId);
    await tenantIdDoc.set({"uid": uid});

    await newRef.set({
      'name': name,
      'status': 'draft', // 下書き保存
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
      'agency': {'code': agentCode, 'linked': false},
    }, SetOptions(merge: true));

    // ❸ 代理店リンク（見つかった場合のみ実施）
    if (shouldTryLinkAgency) {
      await _tryLinkAgencyByCode(
        code: agentCode,
        ownerUid: uid,
        tenantRef: newRef,
        tenantName: name,
        scaffoldContext: context,
      );
    }

    // ❹ UI更新 & 親へ通知（★キーも更新）
    if (!mounted) return;
    setState(() {
      _selectedId = tenantId; // 旧互換
      _selectedKey = _keyOf(uid, tenantId); // 新
    });

    if (widget.onChangedEx != null) {
      widget.onChangedEx!(tenantId, name, uid, false);
    } else {
      widget.onChanged(tenantId, name);
    }

    // ❺ オンボーディング開始（同じ tenantId を渡す）
    await startOnboarding(tenantId, name);

    // ❻ オンボーディング後の状態確認（draftのままでも下書きは残る）
    final snap = await newRef.get();
    if (!mounted) return;

    if (!snap.exists) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.white,
          content: Text(
            'オンボーディングは完了していません（本登録は未保存）',
            style: TextStyle(color: Colors.black87, fontFamily: 'LINEseed'),
          ),
        ),
      );
      return;
    }
  }

  /// 代理店コードが存在するかを事前チェック（status=active のみ有効）
  Future<bool> _agencyCodeExists(String code) async {
    final qs = await FirebaseFirestore.instance
        .collection('agencies')
        .where('code', isEqualTo: code)
        .where('status', isEqualTo: 'active')
        .limit(1)
        .get();
    return qs.docs.isNotEmpty;
  }

  /// 「代理店未連携で続行しますか？」の確認ダイアログ
  Future<bool> _confirmProceedWithoutAgency(
    BuildContext context, {
    required String title,
    required String message,
    String proceedLabel = '続行',
  }) async {
    return await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('戻る'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(proceedLabel),
              ),
            ],
          ),
        ) ??
        false;
  }

  /// 代理店コードから agencies を逆引きし、見つかれば tenant にリンク & contracts を作成
  Future<void> _tryLinkAgencyByCode({
    required String code,
    required String ownerUid,
    required DocumentReference<Map<String, dynamic>> tenantRef,
    required String tenantName,
    required BuildContext scaffoldContext,
  }) async {
    try {
      final qs = await FirebaseFirestore.instance
          .collection('agencies')
          .where('code', isEqualTo: code)
          .where('status', isEqualTo: 'active')
          .limit(1)
          .get();

      if (qs.docs.isEmpty) {
        // コードは保存済み（'agency.code'）なので、ここでは未リンクのままにする
        ScaffoldMessenger.of(scaffoldContext).showSnackBar(
          const SnackBar(content: Text('代理店コードが見つかりませんでした（未リンクのまま保存）')),
        );
        return;
      }

      final agentDoc = qs.docs.first;
      final agentId = agentDoc.id;
      final commissionPercent =
          (agentDoc.data()['commissionPercent'] as num?)?.toInt() ?? 0;

      // tenant の agency 情報を更新（linked=true）
      await tenantRef.set({
        'agency': {
          'code': code,
          'agentId': agentId,
          'commissionPercent': commissionPercent,
          'linked': true,
          'linkedAt': FieldValue.serverTimestamp(),
        },
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      // 代理店配下の contracts にも作成（draft 状態）
      await FirebaseFirestore.instance
          .collection('agencies')
          .doc(agentId)
          .collection('contracts')
          .doc(tenantRef.id)
          .set({
            'tenantId': tenantRef.id,
            'tenantName': tenantName,
            'ownerUid': ownerUid,
            'contractedAt': FieldValue.serverTimestamp(),
            'status': 'draft',
          }, SetOptions(merge: true));

      ScaffoldMessenger.of(
        scaffoldContext,
      ).showSnackBar(SnackBar(content: Text('代理店「$agentId」とリンクしました')));
    } catch (e) {
      ScaffoldMessenger.of(
        scaffoldContext,
      ).showSnackBar(SnackBar(content: Text('代理店リンクに失敗しました: $e')));
    }
  }

  Future<void> startOnboarding(String tenantId, String tenantName) async {
    final size = MediaQuery.of(context).size;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      useRootNavigator: true,
      useSafeArea: true, // ノッチ/セーフエリア考慮
      barrierColor: Colors.black38,
      backgroundColor: Colors.white,
      // ★ これで横幅フル
      constraints: BoxConstraints(minWidth: size.width, maxWidth: size.width),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetCtx) {
        return Theme(
          data: bwTheme(context),
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
      child: StreamBuilder<List<_TenantRow>>(
        stream: _combinedStream,
        builder: (context, snap) {
          if (snap.hasError) {
            return _wrap(
              child: Text(
                '読み込みエラー: ${snap.error}',
                style: const TextStyle(
                  color: Colors.red,
                  fontFamily: 'LINEseed',
                ),
              ),
            );
          }
          if (!snap.hasData) {
            return _wrap(child: const LinearProgressIndicator(minHeight: 2));
          }

          final rows = snap.data!;
          if (rows.isEmpty) {
            return _wrap(
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      '店舗がありません。作成してください。',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: Colors.black87,
                        fontFamily: 'LINEseed',
                      ),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: createTenantDialog,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text(
                      '店舗を作成',
                      style: TextStyle(fontFamily: 'LINEseed'),
                    ),
                    style: _outlineSmall,
                  ),
                ],
              ),
            );
          }

          // ドロップダウン項目（value は複合キー）
          final items = rows.map((r) {
            final name = (r.data['name'] ?? '(no name)').toString();
            final isInvited = r.invited;
            final key = _keyOf(r.ownerUid, r.tenantId);
            return DropdownMenuItem<String>(
              value: key,
              child: Row(
                children: [
                  if (isInvited) ...[
                    const Icon(Icons.group_add, size: 16),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Text(
                      isInvited ? '$name（招待）' : name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.black87,
                        fontFamily: 'LINEseed',
                      ),
                    ),
                  ),
                ],
              ),
            );
          }).toList();

          // 現在選択中の行を決定（優先：_selectedKey → 旧互換：_selectedId）
          _TenantRow? selectedRow;
          if (_selectedKey != null) {
            selectedRow = rows.cast<_TenantRow?>().firstWhere(
              (r) => _keyOf(r!.ownerUid, r.tenantId) == _selectedKey,
              orElse: () => null,
            );
          } else if (_selectedId != null) {
            final uid = _uid;
            // 旧互換：tenantId が一致、かつ自分所有を優先（なければ最初に一致したもの）
            selectedRow = rows.cast<_TenantRow?>().firstWhere(
              (r) => r!.tenantId == _selectedId && r.ownerUid == uid,
              orElse: () => rows.cast<_TenantRow?>().firstWhere(
                (r) => r!.tenantId == _selectedId,
                orElse: () => null,
              ),
            );
            if (selectedRow != null) {
              _selectedKey = _keyOf(selectedRow.ownerUid, selectedRow.tenantId);
            }
          }

          final selectedData = selectedRow?.data;
          final selectedIsDraft = (selectedData?['status'] == 'nonactive');
          final selectedName = (selectedData?['name'] ?? '') as String?;

          return _wrap(
            child: Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    isExpanded: true,
                    isDense: true,
                    value: _selectedKey, // ★複合キーを使う
                    items: items,
                    iconEnabledColor: Colors.black54,
                    dropdownColor: Colors.white,
                    style: const TextStyle(color: Colors.black87, fontSize: 14),
                    onChanged: (key) async {
                      if (key == null || key == _selectedKey) return;

                      // 先に内部状態を更新（UIを即反映）
                      setState(() => _selectedKey = key);

                      final idx = rows.indexWhere(
                        (e) => _keyOf(e.ownerUid, e.tenantId) == key,
                      );
                      final row = idx >= 0 ? rows[idx] : rows.first;

                      final data = row.data;
                      final name = (data['name'] ?? '') as String?;
                      final ownerUid = row.ownerUid;
                      final tenantId = row.tenantId;
                      final invited = row.invited;

                      // 旧互換：_selectedId も併記
                      _selectedId = tenantId;

                      // 未完了なら「続きから再開」ダイアログ
                      if (data['status'] == 'nonactive') {
                        final initStatus =
                            (data['initialFee'] as Map?)?['status'] ?? 'unpaid';
                        final subStatus =
                            (data['subscription'] as Map?)?['status'] ??
                            'inactive';
                        final plan =
                            (data['subscription'] as Map?)?['plan'] as String?;

                        final shouldResume = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text(
                              '下書きがあります',
                              style: TextStyle(fontFamily: 'LINEseed'),
                            ),
                            content: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'この店舗のオンボーディングは未完了です。続きから再開しますか？',
                                  style: TextStyle(fontFamily: 'LINEseed'),
                                ),
                                const SizedBox(height: 12),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    _statusChip('初期費用', initStatus == 'paid'),
                                    _statusChip(
                                      'サブスク',
                                      subStatus == 'active',
                                      trailing: (plan != null)
                                          ? '（$plan）'
                                          : null,
                                    ),
                                  ],
                                ),
                              ],
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, false),
                                child: const Text(
                                  'あとで',
                                  style: TextStyle(fontFamily: 'LINEseed'),
                                ),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(ctx, true),
                                child: const Text(
                                  '再開する',
                                  style: TextStyle(fontFamily: 'LINEseed'),
                                ),
                              ),
                            ],
                          ),
                        );

                        if (shouldResume == true) {
                          await startOnboarding(tenantId, name ?? '');
                        }
                      }

                      // ★ 親へ通知：ExがあればEx、なければ従来API
                      if (widget.onChangedEx != null) {
                        widget.onChangedEx!(tenantId, name, ownerUid, invited);
                      } else {
                        widget.onChanged(tenantId, name);
                      }
                    },
                    decoration: InputDecoration(
                      labelStyle: const TextStyle(color: Colors.black87),
                      floatingLabelStyle: const TextStyle(color: Colors.black),
                      filled: true,
                      fillColor: Colors.white,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 18,
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
                const SizedBox(width: 4),

                // 選択中のときだけ補助ボタンを表示
                if (selectedRow != null && selectedIsDraft)
                  OutlinedButton.icon(
                    onPressed: () async {
                      if (_selectedId == null) return;
                      await startOnboarding(_selectedId!, selectedName ?? '');
                    },
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: const Text(
                      '再開',
                      style: TextStyle(fontFamily: 'LINEseed'),
                    ),
                    style: _outlineSmall,
                  ),
                if (selectedRow != null && !selectedIsDraft)
                  OutlinedButton.icon(
                    onPressed: () async {
                      if (_selectedId == null) return;
                      await startOnboarding(_selectedId!, selectedName ?? '');
                    },
                    label: const Text(
                      '登録状況',
                      style: TextStyle(fontFamily: 'LINEseed'),
                    ),
                    style: _outlineSmall,
                  ),
                const SizedBox(width: 8),

                OutlinedButton.icon(
                  onPressed: createTenantDialog,

                  label: const Text(
                    '新規',
                    style: TextStyle(fontFamily: 'LINEseed'),
                  ),
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

  // 進捗の見える Chip
  Widget _statusChip(String label, bool done, {String? trailing}) {
    return Chip(
      side: const BorderSide(color: Colors.black26),
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(done ? Icons.check_circle : Icons.pause_circle_filled, size: 16),
          const SizedBox(width: 6),
          Text(
            '$label${trailing ?? ''}',
            style: const TextStyle(fontFamily: 'LINEseed'),
          ),
        ],
      ),
      backgroundColor: done ? const Color(0x1100AA00) : const Color(0x11AAAAAA),
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

class _TenantRow {
  final String ownerUid;
  final String tenantId;
  final Map<String, dynamic> data;
  final bool invited; // 招待テナントなら true
  const _TenantRow({
    required this.ownerUid,
    required this.tenantId,
    required this.data,
    required this.invited,
  });
}
