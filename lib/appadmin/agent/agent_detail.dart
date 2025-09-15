import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:yourpay/appadmin/agent/contracts_list_for_agent.dart';

class AgencyDetailPage extends StatelessWidget {
  final String agentId;
  const AgencyDetailPage({super.key, required this.agentId});

  String _ymdhm(DateTime d) =>
      '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final ref = FirebaseFirestore.instance.collection('agencies').doc(agentId);
    final searchCtrl = TextEditingController();

    return Scaffold(
      appBar: AppBar(title: const Text('代理店詳細')),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: ref.snapshots(),
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text('読込エラー: ${snap.error}'));
          if (!snap.hasData)
            return const Center(child: CircularProgressIndicator());

          final m = snap.data!.data() ?? {};
          final name = (m['name'] ?? '(no name)').toString();
          final email = (m['email'] ?? '').toString();
          final code = (m['code'] ?? '').toString();
          final percent = (m['commissionPercent'] ?? 0).toString();
          final status = (m['status'] ?? 'active').toString();
          final createdAt = (m['createdAt'] is Timestamp)
              ? (m['createdAt'] as Timestamp).toDate()
              : null;
          final updatedAt = (m['updatedAt'] is Timestamp)
              ? (m['updatedAt'] as Timestamp).toDate()
              : null;

          return ListView(
            children: [
              ListTile(
                title: Text(
                  name,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Text('Agent ID: $agentId'),
                trailing: IconButton(
                  tooltip: '編集',
                  icon: const Icon(Icons.edit),
                  onPressed: () => _editAgent(context, ref, m),
                ),
              ),
              const Divider(height: 1),
              _kv('メール', email.isNotEmpty ? email : '—'),
              _kv('紹介コード', code.isNotEmpty ? code : '—'),
              _kv('手数料', '$percent%'),
              _kv('ステータス', status),
              if (createdAt != null) _kv('作成', _ymdhm(createdAt)),
              if (updatedAt != null) _kv('更新', _ymdhm(updatedAt)),
              const SizedBox(height: 12),
              const Divider(height: 1),

              // ===== 登録店舗（contracts） =====
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Text(
                  '登録店舗一覧',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),

              // 検索ボックス（tenantName / tenantId / ownerUid などでフィルタ）
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  controller: searchCtrl,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: '店舗名 / tenantId / ownerUid 検索',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => (context as Element).markNeedsBuild(),
                ),
              ),

              ContractsListForAgent(agentId: agentId),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }

  Future<void> _editAgent(
    BuildContext context,
    DocumentReference<Map<String, dynamic>> ref,
    Map<String, dynamic> current,
  ) async {
    final nameC = TextEditingController(
      text: (current['name'] ?? '').toString(),
    );
    final emailC = TextEditingController(
      text: (current['email'] ?? '').toString(),
    );
    final codeC = TextEditingController(
      text: (current['code'] ?? '').toString(),
    );
    final pctC = TextEditingController(
      text: ((current['commissionPercent'] ?? 0)).toString(),
    );
    String status = (current['status'] ?? 'active').toString();

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('代理店情報を編集'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameC,
                decoration: const InputDecoration(labelText: '名称'),
              ),
              TextField(
                controller: emailC,
                decoration: const InputDecoration(labelText: 'メール'),
              ),
              TextField(
                controller: codeC,
                decoration: const InputDecoration(labelText: '紹介コード'),
              ),
              TextField(
                controller: pctC,
                decoration: const InputDecoration(labelText: '手数料(%)'),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: status,
                items: const [
                  DropdownMenuItem(value: 'active', child: Text('active')),
                  DropdownMenuItem(
                    value: 'suspended',
                    child: Text('suspended'),
                  ),
                ],
                onChanged: (v) => status = v ?? 'active',
                decoration: const InputDecoration(labelText: 'ステータス'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );

    if (ok != true) return;

    final pct = int.tryParse(pctC.text.trim());
    await ref.set({
      'name': nameC.text.trim(),
      'email': emailC.text.trim(),
      'code': codeC.text.trim(),
      if (pct != null) 'commissionPercent': pct,
      'status': status,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Widget _kv(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    child: Row(
      children: [
        SizedBox(
          width: 120,
          child: Text(k, style: const TextStyle(color: Colors.black54)),
        ),
        Expanded(child: Text(v)),
      ],
    ),
  );
}
