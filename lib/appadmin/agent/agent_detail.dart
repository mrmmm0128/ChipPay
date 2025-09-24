import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:yourpay/appadmin/agent/contracts_list_for_agent.dart';

class AgencyDetailPage extends StatelessWidget {
  final String agentId;
  final bool agent;
  const AgencyDetailPage({
    super.key,
    required this.agentId,
    required this.agent,
  });

  String _ymdhm(DateTime d) =>
      '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  Future<void> _upsertConnectAndOnboardForAgency(BuildContext context) async {
    try {
      final fn = FirebaseFunctions.instanceFor(
        region: 'us-central1',
      ).httpsCallable('upsertAgencyConnectedAccount');

      final res = await fn.call({
        'agentId': agentId,
        'account': {
          'country': 'JP',
          // 必要なら事前埋め:
          // 'email': 'agency@example.com',
          // 'businessType': 'company', // or 'individual'
          'tosAccepted': true,
        },
      });

      final data = (res.data as Map).cast<String, dynamic>();
      final accountId = (data['accountId'] ?? '').toString();
      final charges = data['chargesEnabled'] == true;
      final payouts = data['payoutsEnabled'] == true;
      final url = data['onboardingUrl'] as String?;
      final anchor = (data['payoutSchedule'] as Map?)?['monthly_anchor'] ?? 1;

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Connect更新完了: $accountId / 入金:${payouts ? "可" : "不可"}／回収:${charges ? "可" : "不可"}／毎月$anchor日',
            ),
          ),
        );
      }

      if (url != null && url.isNotEmpty) {
        await launchUrl(Uri.parse(url));
      }
    } on FirebaseFunctionsException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('失敗: ${e.code} ${e.message ?? ""}')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('失敗: $e')));
      }
    }
  }

  Future<void> _setAgentPassword(BuildContext context) async {
    final pass1 = TextEditingController();
    final pass2 = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('代理店パスワードを設定'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: pass1,
              decoration: const InputDecoration(
                labelText: '新しいパスワード（8文字以上）',
                border: OutlineInputBorder(),
              ),
              obscureText: true,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: pass2,
              decoration: const InputDecoration(
                labelText: '確認用パスワード',
                border: OutlineInputBorder(),
              ),
              obscureText: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('設定'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final p1 = pass1.text;
    final p2 = pass2.text;
    if (p1.length < 8 || p1 != p2) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('パスワード条件エラー：8文字以上＆一致必須')));
      return;
    }

    try {
      final fn = FirebaseFunctions.instanceFor(
        region: 'us-central1',
      ).httpsCallable('adminSetAgencyPassword');
      await fn.call({'agentId': agentId, 'password': p1});
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('パスワードを設定しました')));
    } on FirebaseFunctionsException catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('設定に失敗: ${e.message ?? e.code}')));
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('設定に失敗: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ref = FirebaseFirestore.instance.collection('agencies').doc(agentId);
    final searchCtrl = TextEditingController();

    return Scaffold(
      appBar: AppBar(
        title: const Text('代理店詳細'),
        automaticallyImplyLeading: agent ? false : true,
      ),
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
              // ===== Connect / 入金口座 =====
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Text(
                  '入金口座（Stripe Connect）',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              Builder(
                builder: (ctx) {
                  final m = snap.data!.data() ?? {};
                  final acctId = (m['stripeAccountId'] ?? '').toString();
                  final connect =
                      (m['connect'] as Map?)?.cast<String, dynamic>() ?? {};
                  final charges = connect['charges_enabled'] == true;
                  final payouts = connect['payouts_enabled'] == true;
                  final schedule =
                      (m['payoutSchedule'] as Map?)?.cast<String, dynamic>() ??
                      {};
                  final anchor = schedule['monthly_anchor'] ?? 1;

                  return Column(
                    children: [
                      ListTile(
                        leading: const Icon(
                          Icons.account_balance_wallet_outlined,
                        ),
                        title: Text(acctId.isEmpty ? '未作成' : 'アカウント: $acctId'),
                        subtitle: Text(
                          '入金: ${payouts ? "可" : "不可"} ／ 料金回収: ${charges ? "可" : "不可"} ／ 毎月${anchor}日入金',
                        ),
                        trailing: FilledButton(
                          onPressed: () =>
                              _upsertConnectAndOnboardForAgency(ctx),
                          child: const Text('設定 / 続行'),
                        ),
                      ),
                      const Divider(height: 1),
                    ],
                  );
                },
              ),

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
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: Colors.black),
        ),
        titleTextStyle: const TextStyle(
          color: Colors.black,
          fontSize: 18,
          fontWeight: FontWeight.w700,
        ),
        contentTextStyle: const TextStyle(color: Colors.black),
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
            style: TextButton.styleFrom(
              foregroundColor: Colors.black, // 文字色
              overlayColor: Colors.black12, // 押下時の波紋色も黒系に
            ),
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.black, // 背景
              foregroundColor: Colors.white, // 文字色
              overlayColor: Colors.white12, // 押下時の波紋
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: const BorderSide(color: Colors.black),
              ),
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('保存'),
          ),
          IconButton(
            tooltip: 'パスワード設定',
            icon: const Icon(Icons.key_outlined),
            onPressed: () => _setAgentPassword(context),
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
