import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

class StoreDashboardScreen extends StatefulWidget {
  const StoreDashboardScreen({super.key});

  @override
  State<StoreDashboardScreen> createState() => _StoreDashboardScreenState();
}

class _StoreDashboardScreenState extends State<StoreDashboardScreen> {
  final amountCtrl = TextEditingController(text: '1000');
  String? checkoutUrl;
  String? sessionId;
  bool loading = false;

  String? tenantId;
  String? tenantName;

  @override
  void initState() {
    super.initState();
    // ルート引数を読むのは didChangeDependencies で行う（Routeにアクセスできるため）
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _applyRouteArgsIfAny(); // 一度だけ実行
  }

  bool _argsApplied = false;
  Future<void> _applyRouteArgsIfAny() async {
    if (_argsApplied) return;
    _argsApplied = true;

    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is Map) {
      final id = args['tenantId'] as String?;
      final nameArg = args['tenantName'] as String?;
      if (id != null) {
        setState(() {
          tenantId = id;
          tenantName = nameArg; // 渡されていれば即表示用に使う
        });
        if (nameArg == null) {
          // 渡されなかった場合は Firestore から取得
          final doc = await FirebaseFirestore.instance
              .collection('tenants')
              .doc(id)
              .get();
          if (doc.exists) {
            setState(
              () => tenantName = (doc.data()!['name'] as String?) ?? tenantName,
            );
          }
        }
      }
    }

    // 引数で tenantId が来なかった場合は claims からフォールバック
    if (tenantId == null) {
      final user = FirebaseAuth.instance.currentUser!;
      final token = await user.getIdTokenResult(true);
      final idFromClaims = token.claims?['tenantId'] as String?;
      if (idFromClaims != null) {
        setState(() => tenantId = idFromClaims);
        // 名前は取得していないので見た目用に読み込む
        final doc = await FirebaseFirestore.instance
            .collection('tenants')
            .doc(idFromClaims)
            .get();
        if (doc.exists)
          setState(() => tenantName = doc.data()!['name'] as String?);
      }
    }
  }

  Future<void> createSession() async {
    setState(() => loading = true);
    try {
      final callable = FirebaseFunctions.instance.httpsCallable(
        'createCheckoutSession',
      );
      final result = await callable.call({
        'amount': int.parse(amountCtrl.text),
        'memo': 'Walk-in',
      });
      setState(() {
        checkoutUrl = result.data['checkoutUrl'];
        sessionId = result.data['sessionId'];
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('エラー: $e')));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final titleText = tenantName ?? '店舗ダッシュボード';
    return Scaffold(
      appBar: AppBar(
        title: Text(titleText),
        actions: [
          IconButton(
            onPressed: () async {
              await FirebaseAuth.instance.signOut();
              if (!mounted) return;
              Navigator.pushReplacementNamed(context, '/login');
            },
            icon: const Icon(Icons.logout),
            tooltip: 'Sign out',
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (tenantId == null) ...[
              const SizedBox(height: 24),
              const Center(child: CircularProgressIndicator()),
            ] else ...[
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: amountCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: '金額（円）'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: loading ? null : createSession,
                    icon: const Icon(Icons.qr_code_2),
                    label: const Text('支払用URL発行'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (checkoutUrl != null)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        QrImageView(data: checkoutUrl!, size: 240),
                        const SizedBox(height: 8),
                        SelectableText(
                          checkoutUrl!,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              const Text('直近セッション'),
              const SizedBox(height: 8),
              Expanded(
                child: StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance
                      .collection('paymentSessions')
                      .where('tenantId', isEqualTo: tenantId)
                      .orderBy('createdAt', descending: true)
                      .limit(50)
                      .snapshots(),
                  builder: (context, snap) {
                    if (!snap.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final docs = snap.data!.docs;
                    if (docs.isEmpty)
                      return const Center(child: Text('まだセッションがありません'));
                    return ListView.separated(
                      itemCount: docs.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final d = docs[i].data() as Map<String, dynamic>;
                        final amount = d['amount'];
                        final status = d['status'];
                        final url = d['stripeCheckoutUrl'] ?? '';
                        return ListTile(
                          leading: const Icon(Icons.receipt_long),
                          title: Text('¥$amount  •  $status'),
                          subtitle: Text(
                            url,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Text((d['currency'] ?? 'JPY').toString()),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
