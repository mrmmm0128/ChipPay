// lib/admin/admin_announcement_page.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
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

    final currentUser = FirebaseAuth.instance.currentUser;
    final createdBy = currentUser?.uid ?? 'unknown';

    List<String> tenantIds = const [];
    Map<String, dynamic>? filters;

    switch (_scope) {
      case _TargetScope.all:
        break;
      case _TargetScope.tenantIds:
        tenantIds = _parseTenantIds(_tenantIdsCtrl.text);
        if (tenantIds.isEmpty) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('配信する店舗IDを入力してください')));
          return;
        }
        break;
      case _TargetScope.filters:
        filters = {
          'activeOnly': _filterActiveOnly,
          'chargesEnabledOnly': _filterChargesEnabledOnly,
        };
        break;
    }

    final payload = {
      'title': title,
      'body': body,
      if (url.isNotEmpty) 'url': url,
      'createdAt': FieldValue.serverTimestamp(),
      'createdBy': createdBy,
      'target': {
        'type': _scope.name,
        if (tenantIds.isNotEmpty) 'tenantIds': tenantIds,
        if (filters != null) 'filters': filters,
      },
      'status': 'queued', // functions 側で sent / failed に更新させる前提
    };

    setState(() => _sending = true);
    try {
      // 1) Cloud Functions があれば優先（例: adminBroadcastAnnouncement）
      try {
        final fn = FirebaseFunctions.instance.httpsCallable(
          'adminBroadcastAnnouncement',
        );
        await fn.call({
          'title': title,
          'body': body,
          if (url.isNotEmpty) 'url': url,
          'tenantIds': tenantIds,
          'filters': filters,
        });
      } catch (_) {
        // 2) フォールバック: Firestore にキューを積む
        await FirebaseFirestore.instance
            .collection('adminAnnouncements')
            .add(payload);
      }

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('配信リクエストを送信しました')));
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
