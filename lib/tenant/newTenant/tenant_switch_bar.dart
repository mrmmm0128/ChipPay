import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:yourpay/tenant/newTenant/onboardingSheet.dart';

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
    this.padding = const EdgeInsets.fromLTRB(16, 8, 16, 6),
  });

  @override
  State<TenantSwitcherBar> createState() => _TenantSwitcherBarState();
}

class _TenantSwitcherBarState extends State<TenantSwitcherBar> {
  final _functions = FirebaseFunctions.instanceFor(region: 'us-central1');

  String? _selectedId;
  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  // メモ化した参照
  late final CollectionReference<Map<String, dynamic>> _tenantCol;
  late final Stream<QuerySnapshot<Map<String, dynamic>>> _tenantStream;

  @override
  void initState() {
    super.initState();

    // 初期選択は props からのみ同期（親が決める）
    _selectedId = widget.currentTenantId;

    // ユーザーが未ログインなら以降の処理は行わない（nullチェック）
    final uid = _uid;
    if (uid != null) {
      _tenantCol = FirebaseFirestore.instance.collection(uid);
      // ★ snapshots を1度だけ作成（再購読を防ぐ）
      _tenantStream = _tenantCol.snapshots();
    } else {
      // ダミー（空のstream）…未ログインケース
      _tenantCol = FirebaseFirestore.instance.collection('_');
      _tenantStream = const Stream.empty();
    }
  }

  @override
  void didUpdateWidget(covariant TenantSwitcherBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 親が選択IDを更新したら、その値をそのまま反映（build中に通知はしない）
    if (oldWidget.currentTenantId != widget.currentTenantId) {
      _selectedId = widget.currentTenantId;
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

  // ... 省略（このState内のメンバー: _uid, _selectedId, _functions, bwTheme, OnboardingSheet, widget.onChanged などは既存のまま） ...

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
                    hintText: '例）AGT-XXXXX',
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

    final uid = _uid; // 既存のログイン中ユーザーUID
    if (uid == null) return;

    final tenantsCol = FirebaseFirestore.instance.collection(uid);

    // ❶ 最初に「draft」で本体ドキュメントを作成（このIDを最後まで使う）
    final newRef = tenantsCol.doc(); // 自動ID
    final tenantId = newRef.id;

    await newRef.set({
      'name': name,
      'status': 'draft', // 下書き保存
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
      // 代理店情報（コードだけは必ず保持、リンクは後で試行）
      'agency': {'code': agentCode, 'linked': false},
    }, SetOptions(merge: true));

    // ❷ 代理店コードが入っていれば、agencies を検索してひも付け & contracts 生成
    if (agentCode.isNotEmpty) {
      await _tryLinkAgencyByCode(
        code: agentCode,
        ownerUid: uid,
        tenantRef: newRef,
        tenantName: name,
        scaffoldContext: context,
      );
    }

    // ❸ UI更新 & 親へ通知
    if (!mounted) return;
    setState(() => _selectedId = tenantId);
    widget.onChanged(tenantId, name);

    // ❹ オンボーディング開始（同じ tenantId を渡す）
    await startOnboarding(tenantId, name);

    // ❺ オンボーディング後の状態確認（draftのままでも下書きは残る）
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

    // 既に onChanged 済みなので、ここでは何もしない（必要なら status を見て分岐可能）
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

  // 既存：オンボーディング（変更なし）
  Future<void> startOnboarding(String tenantId, String tenantName) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      useRootNavigator: true,
      barrierColor: Colors.black38,
      backgroundColor: Colors.white,
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
      child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: _tenantStream, // ★ 毎回同じ Stream
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

          final docs = snap.data!.docs;

          // 店舗ゼロ
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

          // ドロップダウン項目
          final items = docs.map((d) {
            final name = (d.data()['name'] ?? '(no name)').toString();
            return DropdownMenuItem<String>(
              value: d.id,
              child: Text(
                name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.black87,
                  fontFamily: 'LINEseed',
                ),
              ),
            );
          }).toList();

          // 現在選択中のドキュメント（_selectedId が null の可能性も考慮）
          QueryDocumentSnapshot<Map<String, dynamic>>? selectedDoc;
          if (_selectedId != null) {
            try {
              selectedDoc = docs.firstWhere((d) => d.id == _selectedId);
            } catch (_) {
              selectedDoc = null;
            }
          }
          final selectedData = selectedDoc?.data();
          final selectedIsDraft = (selectedData?['status'] == 'nonactive');
          final selectedName = (selectedData?['name'] ?? '') as String?;

          return _wrap(
            child: Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    isExpanded: true,
                    isDense: true,
                    value: _selectedId, // ← null なら未選択表示
                    items: items,
                    iconEnabledColor: Colors.black54,
                    dropdownColor: Colors.white,
                    style: const TextStyle(color: Colors.black87, fontSize: 14),
                    onChanged: (v) async {
                      if (v == null || v == _selectedId) return;

                      // 先に内部状態を更新（UIを即反映）
                      setState(() => _selectedId = v);

                      final doc = docs.firstWhere((e) => e.id == v);
                      final data = doc.data();
                      final name = (data['name'] ?? '') as String?;

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
                          await startOnboarding(v, name ?? '');
                        }
                      }

                      // ★ 親へはここで初めて通知（ユーザー選択の完了時）
                      widget.onChanged(v, name);
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

                // 選択中のときだけ補助ボタンを表示
                if (selectedDoc != null && selectedIsDraft)
                  OutlinedButton.icon(
                    onPressed: () async {
                      await startOnboarding(_selectedId!, selectedName ?? '');
                    },
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: const Text(
                      '続きから',
                      style: TextStyle(fontFamily: 'LINEseed'),
                    ),
                    style: _outlineSmall,
                  ),
                if (selectedDoc != null && !selectedIsDraft)
                  OutlinedButton.icon(
                    onPressed: () async {
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
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text(
                    '新規作成',
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
