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
  Future<void> _createTenantDialog() async {
    final nameCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => Theme(
        // ★ 紫対策：ローカル白黒テーマ
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
          'members': [_uid],
          'status': 'active',
          'createdAt': FieldValue.serverTimestamp(),
          'createdBy': {
            'uid': _uid,
            'email': FirebaseAuth.instance.currentUser?.email,
          },
          // まだ未契約の初期状態
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

        // ★ 作成後にオンボーディング起動
        _startOnboarding(ref.id, name);
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
  Future<void> _startOnboarding(String tenantId, String tenantName) async {
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
          child: _OnboardingSheet(
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
                    onPressed: _createTenantDialog,
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
                  onPressed: _createTenantDialog,
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

// --- 小物: ステップ表示用ドット ---
class _StepDot extends StatelessWidget {
  final bool active;
  final String label;
  const _StepDot({required this.active, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: active ? Colors.black87 : Colors.black26,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            color: active ? Colors.black87 : Colors.black54,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

// ---- ボトムシート本体（分離して Theme 適用を確実に） ----
class _OnboardingSheet extends StatefulWidget {
  final String tenantId;
  final String tenantName;
  final FirebaseFunctions functions;
  const _OnboardingSheet({
    required this.tenantId,
    required this.tenantName,
    required this.functions,
  });

  @override
  State<_OnboardingSheet> createState() => _OnboardingSheetState();
}

class _OnboardingSheetState extends State<_OnboardingSheet> {
  int step = 0; // 0: サブスク, 1: メンバー
  String selectedPlan = 'A';
  bool creatingCheckout = false;
  bool inviting = false;
  final inviteCtrl = TextEditingController();
  final invitedEmails = <String>[];

  Future<void> _openCheckout() async {
    if (creatingCheckout) return;
    setState(() => creatingCheckout = true);
    try {
      final res = await widget.functions
          .httpsCallable('createSubscriptionCheckout')
          .call({'tenantId': widget.tenantId, 'plan': selectedPlan});
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
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              backgroundColor: Colors.white,
              content: Text(
                'リンクを取得できませんでした',
                style: TextStyle(color: Colors.black87),
              ),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.white,
            content: Text(
              'チェックアウト作成に失敗: $e',
              style: const TextStyle(color: Colors.black87),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => creatingCheckout = false);
    }
  }

  Future<void> _inviteMember() async {
    final email = inviteCtrl.text.trim();
    if (email.isEmpty) return;
    if (inviting) return;
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.white,
            content: Text(
              '招待を送信しました: $email',
              style: const TextStyle(color: Colors.black87),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.white,
            content: Text(
              '招待に失敗: $e',
              style: const TextStyle(color: Colors.black87),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => inviting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget planChips() {
      Widget chip(String label, String value) {
        final selected = selectedPlan == value;
        return ChoiceChip(
          selected: selected,
          label: Text(
            label,
            style: const TextStyle(
              color: Colors.black87,
              fontWeight: FontWeight.w600,
            ),
          ),
          selectedColor: Colors.black12,
          side: const BorderSide(color: Colors.black26),
          onSelected: (_) => setState(() => selectedPlan = value),
        );
      }

      return Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          chip('A（20%）', 'A'),
          chip('B（15%）', 'B'),
          chip('C（10%）', 'C'),
        ],
      );
    }

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scroll) {
        return SingleChildScrollView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
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

              // Step 表示
              Row(
                children: const [
                  _StepDot(active: true, label: 'サブスク登録'),
                  SizedBox(width: 12),
                  _StepDot(active: false, label: 'メンバー追加'),
                ],
              ),
              const SizedBox(height: 16),

              if (step == 0) ...[
                const Text(
                  'プランを選択し、登録へ進んでください。',
                  style: TextStyle(color: Colors.black87),
                ),
                const SizedBox(height: 12),
                planChips(),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: creatingCheckout ? null : _openCheckout,
                        icon: creatingCheckout
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.open_in_new),
                        label: const Text('登録へ進む（チェックアウト）'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton(
                      onPressed: () => setState(() => step = 1),
                      child: const Text('あとで'),
                    ),
                  ],
                ),
              ] else ...[
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
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
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
                  const Text(
                    '送信済み招待:',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
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
              ],
            ],
          ),
        );
      },
    );
  }
}
