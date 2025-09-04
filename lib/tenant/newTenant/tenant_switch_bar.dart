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
    this.padding = const EdgeInsets.fromLTRB(16, 8, 16, 6), // ★ smaller
  });

  @override
  State<TenantSwitcherBar> createState() => _TenantSwitcherBarState();
}

class _TenantSwitcherBarState extends State<TenantSwitcherBar> {
  final _functions = FirebaseFunctions.instanceFor(region: 'us-central1');

  String? _selectedId;
  final uid = FirebaseAuth.instance.currentUser?.uid;

  Query<Map<String, dynamic>> _queryForUserTenants() {
    // TODO: 必要なら membership 条件に変更
    return FirebaseFirestore.instance.collection(uid!);
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

  // ---------- テナント作成ダイアログ ----------
  Future<void> createTenantDialog() async {
    final nameCtrl = TextEditingController();

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
            title: const Text('新しい店舗を作成'),
            content: TextField(
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
            actionsPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 8,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                style: TextButton.styleFrom(foregroundColor: Colors.black87),
                child: const Text('キャンセル'),
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
                child: const Text('作成'),
              ),
            ],
          ),
        ),
      ),
    );

    if (ok != true) return;

    final name = nameCtrl.text.trim();
    if (name.isEmpty) return;

    // Firestore の doc はまだ作らない。まずは ID を予約
    final tenants = FirebaseFirestore.instance.collection(uid!);
    final String tempTenantId = tenants.doc().id;

    // 3ボタン版 OnboardingSheet（同一モーダル内で 初期費用/サブスク/Connect を進める & 「保存する」）
    await startOnboarding(tempTenantId, name);

    // シートを閉じた時点で、本登録（= tenants/{id} が作られたか）を確認
    final snap = await tenants.doc(tempTenantId).get();
    if (!mounted) return;

    if (!snap.exists) {
      // まだ「保存する」を押していない（or サブスク未完了等）
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.white,
          content: Text(
            'オンボーディングは完了していません（本登録は未保存）',
            style: TextStyle(color: Colors.black87),
          ),
        ),
      );
      return;
    }

    // ここに来たら「保存」済み＝本登録作成済み
    setState(() => _selectedId = tempTenantId);
    widget.onChanged(tempTenantId, name);
  }

  // ---------- オンボーディング（モーダル/ステッパー） ----------
  Future<void> startOnboarding(String tenantId, String tenantName) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true, // シートを大きくできる（DraggableScrollableSheetに最適）
      isDismissible: false, // 外側タップで閉じない
      enableDrag: false, // 引っ張っても閉じない
      useRootNavigator: true, // ルートNavigatorで全画面を覆う（ネスト対策）
      barrierColor: Colors.black38, // 半透明バリア（背面をブロック）
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetCtx) {
        // ★ 紫対策：ボトムシート全体を白黒テーマで包む
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

          // ドロップダウン項目（下書きラベル付与）
          final items = docs.map((d) {
            final data = d.data();
            final isDraft = (data['status'] == 'nonactive');
            final name = (data['name'] ?? '(no name)').toString();
            return DropdownMenuItem<String>(
              value: d.id,
              child: Text(
                isDraft ? '$name（下書き）' : name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.black87),
              ),
            );
          }).toList();

          // 選択IDの初期化/補正
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

          // 現在選択中のドキュメント
          QueryDocumentSnapshot<Map<String, dynamic>>? selectedDoc;
          try {
            selectedDoc = docs.firstWhere((d) => d.id == _selectedId);
          } catch (_) {
            selectedDoc = null;
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
                    value: _selectedId,
                    items: items,
                    iconEnabledColor: Colors.black54,
                    dropdownColor: Colors.white,
                    style: const TextStyle(color: Colors.black87, fontSize: 14),
                    onChanged: (v) async {
                      if (v == null) return;
                      setState(() => _selectedId = v);

                      final doc = docs.firstWhere((e) => e.id == v);
                      final data = doc.data();
                      final name = (data['name'] ?? '') as String?;
                      widget.onChanged(v, name);

                      // ★ 未完了なら「続きから再開」ダイアログを出す
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
                            title: const Text('下書きがあります'),
                            content: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('この店舗のオンボーディングは未完了です。続きから再開しますか？'),
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
                                    // 必要なら Connect などもここに追加
                                  ],
                                ),
                              ],
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, false),
                                child: const Text('あとで'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(ctx, true),
                                child: const Text('再開する'),
                              ),
                            ],
                          ),
                        );

                        if (shouldResume == true) {
                          await startOnboarding(v, name ?? '');
                        }
                      }
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
                if (selectedIsDraft)
                  OutlinedButton.icon(
                    onPressed: () async {
                      // ダイアログ省略で即再開
                      await startOnboarding(_selectedId!, selectedName ?? '');
                    },
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: const Text('続きから'),
                    style: _outlineSmall,
                  ),
                const SizedBox(width: 8),
                if (!selectedIsDraft)
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

  // 進捗の見える Chip
  Widget _statusChip(String label, bool done, {String? trailing}) {
    return Chip(
      side: const BorderSide(color: Colors.black26),
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(done ? Icons.check_circle : Icons.pause_circle_filled, size: 16),
          const SizedBox(width: 6),
          Text('$label${trailing ?? ''}'),
        ],
      ),
      backgroundColor: done
          ? const Color(0x1100AA00) // 薄い緑
          : const Color(0x11AAAAAA), // 薄いグレー
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
