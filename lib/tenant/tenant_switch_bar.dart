// lib/tenant/widgets/tenant_switcher_bar.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

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
  late final String _uid = FirebaseAuth.instance.currentUser!.uid;
  String? _selectedId;

  Query<Map<String, dynamic>> _queryForUserTenants() {
    // TODO: 必要なら membership 条件に変更
    return FirebaseFirestore.instance
        .collection('tenants')
        .orderBy('createdAt', descending: true);
  }

  Future<void> _createTenantDialog() async {
    final nameCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('新しい店舗を作成', style: TextStyle(color: Colors.black87)),
        content: TextField(
          controller: nameCtrl,
          decoration: const InputDecoration(
            labelText: '店舗名',
            labelStyle: TextStyle(color: Colors.black87),
            hintText: '例）渋谷店',
            hintStyle: TextStyle(color: Colors.black54),
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
        });
        if (!mounted) return;

        setState(() => _selectedId = ref.id);
        widget.onChanged(ref.id, name);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('店舗を作成しました')));
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('作成に失敗: $e')));
      }
    }
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
                        color: Colors.black87, // ★ 黒
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
                    style: const TextStyle(color: Colors.black87), // ★ 黒
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
                    isDense: true, // ★ コンパクト
                    value: _selectedId,
                    items: items,
                    iconEnabledColor: Colors.black54,
                    dropdownColor: Colors.white,
                    style: const TextStyle(
                      color: Colors.black87, // ★ 入力文字色
                      fontSize: 14,
                    ),
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
                      labelStyle: const TextStyle(color: Colors.black87), // ★ 黒
                      floatingLabelStyle: const TextStyle(
                        color: Colors.black,
                      ), // ★ 黒
                      filled: true,
                      fillColor: Colors.white,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8, // ★ 縦幅を小さく
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
                    // さらに詰める
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
        color: Colors.transparent, // ★ 背景なし
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.black12), // ★ 細い枠のみ
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8), // ★ 小さめ
      child: child,
    );
  }

  ButtonStyle get _outlineSmall => OutlinedButton.styleFrom(
    foregroundColor: Colors.black87,
    side: const BorderSide(color: Colors.black45),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8), // ★ 小さめ
    textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
    visualDensity: VisualDensity.compact, // ★ コンパクト
  );
}
