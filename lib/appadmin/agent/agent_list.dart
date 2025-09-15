// 代理店一覧（タップで代理店詳細ページへ遷移）
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:yourpay/appadmin/agent/agent_detail.dart';

class AgentsList extends StatelessWidget {
  final String query;
  const AgentsList({required this.query});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('agencies')
          .orderBy('createdAt', descending: true)
          .snapshots(),
      builder: (context, snap) {
        if (snap.hasError) return Center(child: Text('読込エラー: ${snap.error}'));
        if (!snap.hasData)
          return const Center(child: CircularProgressIndicator());

        var docs = snap.data!.docs;
        final q = query.trim().toLowerCase();
        if (q.isNotEmpty) {
          docs = docs.where((d) {
            final m = d.data();
            final name = (m['name'] ?? '').toString().toLowerCase();
            final email = (m['email'] ?? '').toString().toLowerCase();
            final code = (m['code'] ?? '').toString().toLowerCase();
            return name.contains(q) ||
                email.contains(q) ||
                code.contains(q) ||
                d.id.toLowerCase().contains(q);
          }).toList();
        }

        if (docs.isEmpty) return const Center(child: Text('代理店がありません'));

        return ListView.separated(
          itemCount: docs.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, i) {
            final d = docs[i];
            final m = d.data();
            final name = (m['name'] ?? '(no name)').toString();
            final email = (m['email'] ?? '').toString();
            final code = (m['code'] ?? '').toString();
            final percent = (m['commissionPercent'] ?? 0).toString();
            final status = (m['status'] ?? 'active').toString();

            return ListTile(
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => AgencyDetailPage(agentId: d.id),
                    settings: RouteSettings(arguments: {'agentId': d.id}),
                  ),
                );
              },
              leading: const Icon(Icons.apartment),
              title: Text(
                name,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                [
                  if (email.isNotEmpty) email,
                  if (code.isNotEmpty) 'code: $code',
                  '手数料: $percent%',
                  'status: $status',
                ].join('  •  '),
              ),
              trailing: const Icon(Icons.chevron_right),
            );
          },
        );
      },
    );
  }
}
