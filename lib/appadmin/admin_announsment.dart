// lib/admin/admin_announcement_page.dart
import 'dart:math' as math;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

enum _TargetScope { all, tenantIds, filters }

class AdminAnnouncementPage extends StatefulWidget {
  const AdminAnnouncementPage({super.key});

  @override
  State<AdminAnnouncementPage> createState() => _AdminAnnouncementPageState();
}

class _AdminAnnouncementPageState extends State<AdminAnnouncementPage> {
  final _titleCtrl = TextEditingController();
  final _bodyCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  final _tenantIdsCtrl = TextEditingController();

  _TargetScope _scope = _TargetScope.all;
  bool _filterActiveOnly = true;
  bool _filterChargesEnabledOnly = false;
  bool _sending = false;

  @override
  void dispose() {
    _titleCtrl.dispose();
    _bodyCtrl.dispose();
    _urlCtrl.dispose();
    _tenantIdsCtrl.dispose();
    super.dispose();
  }

  List<String> _parseTenantIds(String raw) {
    if (raw.trim().isEmpty) return const [];
    final parts = raw
        .split(RegExp(r'[\s,、\n\r\t]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList();
    parts.sort();
    return parts;
  }

  /// 対象テナントを tenantIndex から解決して {tenantId, ownerUid} の配列で返す
  Future<List<Map<String, String>>> _resolveTargets({
    required _TargetScope scope,
    required List<String> tenantIds,
    required bool activeOnly,
    required bool chargesEnabledOnly,
  }) async {
    final idxCol = FirebaseFirestore.instance.collection('tenantIndex');
    final List<Map<String, String>> out = [];

    if (scope == _TargetScope.tenantIds) {
      // 個別指定は ID で引く
      for (final id in tenantIds) {
        final doc = await idxCol.doc(id).get();
        if (!doc.exists) continue;
        final data = doc.data()!;
        final uid = (data['uid'] as String?) ?? '';
        if (uid.isEmpty) continue;

        // クライアントフィルタ（要件に合わせて緩く判定）
        if (activeOnly && ((data['status'] as String?) ?? '') != 'active') {
          continue;
        }
        if (chargesEnabledOnly &&
            !(((data['connect'] as Map?)?['charges_enabled']) == true)) {
          continue;
        }

        out.add({'tenantId': id, 'ownerUid': uid});
      }
      return out;
    }

    // all / filters は全件を取ってクライアントでフィルタ（件数が多い場合は Functions 化を検討）
    final snap = await idxCol.get();
    for (final d in snap.docs) {
      final data = d.data();
      final uid = (data['uid'] as String?) ?? '';
      if (uid.isEmpty) continue;

      if (activeOnly && ((data['status'] as String?) ?? '') != 'active') {
        continue;
      }
      if (chargesEnabledOnly &&
          !(((data['connect'] as Map?)?['charges_enabled']) == true)) {
        continue;
      }
      out.add({'tenantId': d.id, 'ownerUid': uid});
    }
    return out;
  }

  /// WriteBatch を 500 件単位で分割コミット
  Future<void> _commitAlertsInBatches(
    List<Map<String, String>> targets, {
    required Map<String, dynamic> alertPayloadBase,
  }) async {
    const limit = 480; // 余裕をみて 480/バッチ
    for (int i = 0; i < targets.length; i += limit) {
      final slice = targets.sublist(i, math.min(i + limit, targets.length));
      final batch = FirebaseFirestore.instance.batch();

      for (final t in slice) {
        final ownerUid = t['ownerUid']!;
        final tenantId = t['tenantId']!;
        final ref = FirebaseFirestore.instance
            .collection(ownerUid)
            .doc(tenantId)
            .collection('alerts')
            .doc();
        batch.set(ref, {
          ...alertPayloadBase,
          'sentAt': FieldValue.serverTimestamp(),
        });
      }

      await batch.commit();
    }
  }

  Future<void> _send() async {
    final title = _titleCtrl.text.trim();
    final body = _bodyCtrl.text.trim();
    final url = _urlCtrl.text.trim();

    if (title.isEmpty || body.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('タイトルと本文は必須です')));
      return;
    }

    // 対象抽出
    List<String> tenantIds = const [];
    if (_scope == _TargetScope.tenantIds) {
      tenantIds = _parseTenantIds(_tenantIdsCtrl.text);
      if (tenantIds.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('配信する店舗IDを入力してください')));
        return;
      }
    }

    setState(() => _sending = true);
    try {
      final targets = await _resolveTargets(
        scope: _scope,
        tenantIds: tenantIds,
        activeOnly: _scope == _TargetScope.filters ? _filterActiveOnly : false,
        chargesEnabledOnly: _scope == _TargetScope.filters
            ? _filterChargesEnabledOnly
            : false,
      );

      if (targets.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('配信対象が見つかりませんでした')));
        setState(() => _sending = false);
        return;
      }

      // alerts に書くペイロード（※読み側の実装に合わせて message / read を必須で入れる）
      final currentUser = FirebaseAuth.instance.currentUser;
      final alertPayloadBase = <String, dynamic>{
        'type': 'admin_announcement',
        'title': title,
        'message': body, // ← 既存の読み手が使うフィールド
        if (url.isNotEmpty) 'url': url,
        'read': false,
        'createdAt': FieldValue.serverTimestamp(),
        'createdBy': {'uid': currentUser?.uid, 'email': currentUser?.email},
      };

      await _commitAlertsInBatches(targets, alertPayloadBase: alertPayloadBase);

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('配信しました（${targets.length} 件）')));
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('送信に失敗しました: $e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('お知らせ配信')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _titleCtrl,
            decoration: const InputDecoration(
              labelText: 'タイトル *',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _bodyCtrl,
            minLines: 5,
            maxLines: 10,
            decoration: const InputDecoration(
              labelText: '本文 *',
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _urlCtrl,
            decoration: const InputDecoration(
              labelText: 'リンクURL（任意）',
              border: OutlineInputBorder(),
              hintText: 'https://example.com',
            ),
          ),
          const SizedBox(height: 16),
          const Text('配信対象', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          RadioListTile<_TargetScope>(
            value: _TargetScope.all,
            groupValue: _scope,
            onChanged: (v) => setState(() => _scope = v!),
            title: const Text('全店舗'),
          ),
          RadioListTile<_TargetScope>(
            value: _TargetScope.tenantIds,
            groupValue: _scope,
            onChanged: (v) => setState(() => _scope = v!),
            title: const Text('店舗IDを指定'),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 8),
                TextField(
                  controller: _tenantIdsCtrl,
                  minLines: 2,
                  maxLines: 4,
                  enabled: _scope == _TargetScope.tenantIds,
                  decoration: const InputDecoration(
                    hintText: 'カンマ / スペース / 改行区切りで入力（例: tenA, tenB tenC）',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          RadioListTile<_TargetScope>(
            value: _TargetScope.filters,
            groupValue: _scope,
            onChanged: (v) => setState(() => _scope = v!),
            title: const Text('フィルタで配信'),
            subtitle: Column(
              children: [
                SwitchListTile(
                  title: const Text('status: active のみ'),
                  value: _filterActiveOnly,
                  onChanged: _scope == _TargetScope.filters
                      ? (v) => setState(() => _filterActiveOnly = v)
                      : null,
                ),
                SwitchListTile(
                  title: const Text('charges_enabled のみ'),
                  value: _filterChargesEnabledOnly,
                  onChanged: _scope == _TargetScope.filters
                      ? (v) => setState(() => _filterChargesEnabledOnly = v)
                      : null,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _sending ? null : _send,
              icon: _sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send),
              label: Text(_sending ? '送信中…' : '配信する'),
            ),
          ),
        ],
      ),
    );
  }
}
