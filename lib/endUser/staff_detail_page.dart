import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:yourpay/endUser/tip_complete_page.dart';
import 'package:yourpay/endUser/tip_waiting_page.dart';

class StaffDetailPage extends StatefulWidget {
  const StaffDetailPage({super.key});
  @override
  State<StaffDetailPage> createState() => _StaffDetailPageState();
}

class _StaffDetailPageState extends State<StaffDetailPage> {
  String? tenantId;
  String? employeeId;
  String? name;
  String? email;
  String? photoUrl;
  String? tenantName;

  final _amountCtrl = TextEditingController(text: '500'); // デフォルト500
  bool _loading = false;

  static const int _maxAmount = 1000000; // バックエンド制限と合わせる

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is Map) {
      tenantId = args['tenantId'] as String?;
      employeeId = args['employeeId'] as String?;
      name = args['name'] as String?;
      email = args['email'] as String?;
      photoUrl = args['photoUrl'] as String?;
      tenantName = args['tenantName'] as String?;
      setState(() {});
    }
  }

  @override
  void initState() {
    super.initState();
    _initFromUrlIfNeeded(); // ← 追加：URL直叩き対応
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    super.dispose();
  }

  int _currentAmount() {
    final v = int.tryParse(_amountCtrl.text) ?? 0;
    return v.clamp(0, _maxAmount);
  }

  void _initFromUrlIfNeeded() {
    if (tenantId != null && employeeId != null) return;

    final uri = Uri.base;

    // 通常のクエリ（?key=value）
    final qp1 = uri.queryParameters;

    // ハッシュルーター（/#/staff?key=value）内のクエリも拾う
    final frag = uri.fragment; // 例: "/staff?t=xxx&e=yyy"
    Map<String, String> qp2 = {};
    final qIndex = frag.indexOf('?');
    if (qIndex >= 0 && qIndex < frag.length - 1) {
      qp2 = Uri.splitQueryString(frag.substring(qIndex + 1));
    }

    String? pick(String a, String b) {
      return qp2[a] ?? qp2[b] ?? qp1[a] ?? qp1[b];
    }

    tenantId = tenantId ?? pick('t', 'tenantId');
    employeeId = employeeId ?? pick('e', 'employeeId');
    name = name ?? pick('name', 'n');
    email = email ?? pick('email', 'mail');
    photoUrl = photoUrl ?? pick('photoUrl', 'p');
    tenantName = tenantName ?? pick('tenantName', 'store');

    // 初期金額（任意）
    final initAmount = pick('a', 'amount');
    if (initAmount != null && initAmount.isNotEmpty) {
      _amountCtrl.text = initAmount;
    }

    setState(() {});
    _maybeFetchFromFirestore();
  }

  Future<void> _maybeFetchFromFirestore() async {
    if (tenantId == null || employeeId == null) return;
    // name/photo が無いときだけ取得
    if (name == null ||
        name!.isEmpty ||
        photoUrl == null ||
        photoUrl!.isEmpty) {
      final empDoc = await FirebaseFirestore.instance
          .collection('tenants')
          .doc(tenantId)
          .collection('employees')
          .doc(employeeId)
          .get();
      if (empDoc.exists) {
        final d = empDoc.data()!;
        name ??= d['name'] as String?;
        email ??= d['email'] as String?;
        photoUrl ??= d['photoUrl'] as String?;
      }
    }
    if (tenantName == null || tenantName!.isEmpty) {
      final tDoc = await FirebaseFirestore.instance
          .collection('tenants')
          .doc(tenantId)
          .get();
      if (tDoc.exists) {
        tenantName = tDoc.data()?['name'] as String?;
      }
    }
    if (mounted) setState(() {});
  }

  void _setAmount(int v) {
    final clamped = v.clamp(0, _maxAmount);
    _amountCtrl.text = clamped.toString();
    setState(() {});
  }

  Future<void> _ensureAnonSignIn() async {
    final auth = FirebaseAuth.instance;
    if (auth.currentUser == null) {
      await auth.signInAnonymously();
    }
  }

  Future<void> _sendTip() async {
    if (tenantId == null || employeeId == null) return;
    final amount = _currentAmount();
    if (amount <= 0) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('有効な金額を入力してください')));
      return;
    }
    if (amount > _maxAmount) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('金額が大きすぎます（最大100万円）')));
      return;
    }

    setState(() => _loading = true);
    try {
      final callable = FirebaseFunctions.instance.httpsCallable(
        'createTipSessionPublic',
      );
      final result = await callable.call({
        'tenantId': tenantId,
        'employeeId': employeeId,
        'amount': amount,
        'memo': 'Tip to ${name ?? ''}',
      });

      final data = Map<String, dynamic>.from(result.data as Map);
      final checkoutUrl = data['checkoutUrl'] as String;
      final sessionId = data['sessionId'] as String;

      // Stripe Checkout へ
      await launchUrlString(checkoutUrl, mode: LaunchMode.externalApplication);
      await _ensureAnonSignIn();

      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => TipWaitingPage(
            sessionId: sessionId,
            tenantId: tenantId!,
            tenantName: tenantName,
            amount: amount,
            employeeName: name,
            checkoutUrl: checkoutUrl,
          ),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('エラー: $e')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _fmt(int n) => n.toString();

  @override
  Widget build(BuildContext context) {
    final title = name ?? 'スタッフ詳細';
    final presets = const [100, 300, 500, 1000, 3000, 5000, 10000];

    final cardDecoration = BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 12)],
    );

    return Scaffold(
      backgroundColor: Colors.grey[100],
      appBar: AppBar(
        title: Text(title),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 0.5,
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  // 縦が小さい端末でもスクロールで対応
                  minHeight: constraints.maxHeight - 40,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // ===== プロフィールカード =====
                    Container(
                      decoration: cardDecoration,
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          CircleAvatar(
                            radius: 36,
                            backgroundImage:
                                (photoUrl != null && photoUrl!.isNotEmpty)
                                ? NetworkImage(photoUrl!)
                                : null,
                            child: (photoUrl == null || photoUrl!.isEmpty)
                                ? const Icon(Icons.person, size: 36)
                                : null,
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        title,
                                        style: const TextStyle(
                                          fontSize: 20,
                                          fontWeight: FontWeight.w700,
                                          color: Colors.black87,
                                        ),
                                      ),
                                    ),
                                    if (tenantName != null &&
                                        tenantName!.isNotEmpty)
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 6,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.grey[100],
                                          borderRadius: BorderRadius.circular(
                                            20,
                                          ),
                                          border: Border.all(
                                            color: Colors.black12,
                                          ),
                                        ),
                                        child: Text(
                                          tenantName!,
                                          style: const TextStyle(
                                            fontSize: 12,
                                            color: Colors.black87,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                if (email != null && email!.isNotEmpty)
                                  Row(
                                    children: [
                                      const Icon(
                                        Icons.mail_outline,
                                        size: 16,
                                        color: Colors.black54,
                                      ),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          email!,
                                          style: const TextStyle(
                                            color: Colors.black87,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                // if (employeeId != null) ...[
                                //   const SizedBox(height: 4),
                                //   Row(
                                //     children: [
                                //       const Icon(
                                //         Icons.badge_outlined,
                                //         size: 16,
                                //         color: Colors.black54,
                                //       ),
                                //       const SizedBox(width: 6),
                                //       Expanded(
                                //         child: Text(
                                //           'ID: $employeeId',
                                //           style: const TextStyle(
                                //             color: Colors.black54,
                                //           ),
                                //           overflow: TextOverflow.ellipsis,
                                //         ),
                                //       ),
                                //     ],
                                //   ),
                                // ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 14),

                    // ===== 金額カード（表示＋プリセット）=====
                    Container(
                      decoration: cardDecoration,
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              const Text(
                                '金額',
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: Colors.black87,
                                ),
                              ),
                              const Spacer(),
                              TextButton.icon(
                                onPressed: () => _setAmount(0),
                                icon: const Icon(Icons.clear),
                                label: const Text('クリア'),
                              ),
                            ],
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 14,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.black12),
                            ),
                            child: Row(
                              children: [
                                const Text(
                                  '¥',
                                  style: TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    _fmt(_currentAmount()),
                                    textAlign: TextAlign.right,
                                    style: const TextStyle(
                                      fontSize: 30,
                                      fontWeight: FontWeight.w800,
                                      color: Colors.black87,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: presets.map((v) {
                              final active = _currentAmount() == v;
                              return ChoiceChip(
                                backgroundColor: active
                                    ? const Color(0xFF111111)
                                    : Colors.grey[100],
                                selected: active,
                                label: Text('¥${_fmt(v)}'),
                                showCheckmark: false,
                                selectedColor: const Color(0xFF111111),
                                labelStyle: TextStyle(
                                  color: active ? Colors.white : Colors.black87,
                                  fontWeight: FontWeight.w600,
                                ),
                                onSelected: (_) => _setAmount(v),
                              );
                            }).toList(),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 14),

                    // ===== キーパッドカード =====
                    Container(
                      decoration: cardDecoration,
                      padding: const EdgeInsets.all(12),
                      child: _AmountKeypad(
                        onTapDigit: (d) {
                          final curr = _currentAmount();
                          final next = (curr * 10 + d);
                          if (next <= _maxAmount) _setAmount(next);
                        },
                        onTapDoubleZero: () {
                          final curr = _currentAmount();
                          final next = (curr == 0) ? 0 : (curr * 100);
                          if (next <= _maxAmount) _setAmount(next);
                        },
                        onBackspace: () {
                          final curr = _currentAmount();
                          _setAmount(curr ~/ 10);
                        },
                      ),
                    ),

                    const SizedBox(height: 18),

                    // ===== 送信ボタン =====
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _loading ? null : _sendTip,
                        icon: const Icon(Icons.volunteer_activism),
                        label: _loading
                            ? const SizedBox(
                                height: 16,
                                width: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('Stripeでチップを送る'),
                      ),
                    ),

                    // ===== 開発用：決済完了画面へ遷移 =====
                    const SizedBox(height: 4),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _loading
                            ? null
                            : () {
                                if (tenantId == null || employeeId == null) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('スタッフ情報が不明です'),
                                    ),
                                  );
                                  return;
                                }
                                final amount = _currentAmount();
                                if (amount <= 0) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('有効な金額を入力してください'),
                                    ),
                                  );
                                  return;
                                }
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => TipCompletePage(
                                      tenantId: tenantId!,
                                      tenantName: tenantName ?? '店舗',
                                      employeeName: name,
                                      amount: amount,
                                    ),
                                  ),
                                );
                              },
                        icon: const Icon(Icons.volunteer_activism),
                        label: _loading
                            ? const SizedBox(
                                height: 16,
                                width: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('決済完了画面へ遷移'),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 画面内テンキー（1–9 / 00 / 0 / ⌫）
class _AmountKeypad extends StatelessWidget {
  final void Function(int digit) onTapDigit;
  final VoidCallback onTapDoubleZero;
  final VoidCallback onBackspace;

  const _AmountKeypad({
    required this.onTapDigit,
    required this.onTapDoubleZero,
    required this.onBackspace,
  });

  @override
  Widget build(BuildContext context) {
    // グリッドレイアウト 3 x 4
    final buttons = <Widget>[
      for (var i = 1; i <= 9; i++) _numBtn('$i', () => onTapDigit(i)),
      _numBtn('00', onTapDoubleZero),
      _numBtn('0', () => onTapDigit(0)),
      _iconBtn(Icons.backspace_outlined, onBackspace),
    ];

    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 1.6, // 横長めで押しやすく
      children: buttons,
    );
  }

  Widget _numBtn(String label, VoidCallback onPressed) {
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        elevation: 0,
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        side: const BorderSide(color: Colors.black12),
        padding: const EdgeInsets.symmetric(vertical: 14),
        textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
      ),
      child: Text(label),
    );
  }

  Widget _iconBtn(IconData icon, VoidCallback onPressed) {
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        elevation: 0,
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        side: const BorderSide(color: Colors.black12),
        padding: const EdgeInsets.symmetric(vertical: 14),
      ),
      child: Icon(icon, size: 22),
    );
  }
}
