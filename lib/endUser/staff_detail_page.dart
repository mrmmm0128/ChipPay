import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:yourpay/endUser/tip_complete_page.dart';
import 'package:yourpay/endUser/tip_waiting_page.dart';
import 'package:google_fonts/google_fonts.dart';

class StaffDetailPage extends StatefulWidget {
  const StaffDetailPage({super.key});
  @override
  State<StaffDetailPage> createState() => _StaffDetailPageState();
}

class _StaffDetailPageState extends State<StaffDetailPage> {
  // ===== デザイン用の統一カラー・線の太さ =====
  static const Color kBlack = Color(0xFF000000);
  static const Color kWhite = Color(0xFFFFFFFF);
  static const Color kYellow = Color(0xFFFCC400); // 黄色
  static const double kBorderWidth = 5.0;

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
    _initFromUrlIfNeeded(); // URL直叩き対応
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
    if (amount < 100) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('チップは100円から送ることができます')));
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
      await launchUrlString(
        checkoutUrl,
        mode: LaunchMode.platformDefault, // Webは同タブ
        webOnlyWindowName: '_self', // 同じタブに強制
      );
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
    final presets = const [1000, 3000, 5000, 10000];

    final cardDecoration = BoxDecoration(
      color: kWhite,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: kBlack, width: kBorderWidth),
      boxShadow: [
        BoxShadow(
          color: kBlack.withOpacity(0.06),
          blurRadius: 8,
          offset: const Offset(0, 3),
        ),
      ],
    );

    return Scaffold(
      backgroundColor: kYellow,
      appBar: AppBar(
        title: Text(title, style: const TextStyle(color: kBlack)),
        backgroundColor: kWhite,
        foregroundColor: kBlack,
        elevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(kBorderWidth),
          child: Container(height: kBorderWidth, color: kBlack),
        ),
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(12, 14, 12, 24),
              child: ConstrainedBox(
                constraints: BoxConstraints(
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
                          // 黒の太枠付きアバター
                          Container(
                            width: 72,
                            height: 72,
                            decoration: BoxDecoration(
                              color: kWhite,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: kBlack,
                                width: kBorderWidth,
                              ),
                            ),
                            child: CircleAvatar(
                              backgroundColor: kWhite,
                              radius: 36,
                              backgroundImage:
                                  (photoUrl != null && photoUrl!.isNotEmpty)
                                  ? NetworkImage(photoUrl!)
                                  : null,
                              child: (photoUrl == null || photoUrl!.isEmpty)
                                  ? const Icon(
                                      Icons.person,
                                      size: 36,
                                      color: kBlack,
                                    )
                                  : null,
                            ),
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
                                          color: kBlack,
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
                                          color: kYellow,
                                          borderRadius: BorderRadius.circular(
                                            20,
                                          ),
                                          border: Border.all(
                                            color: kBlack,
                                            width: kBorderWidth,
                                          ),
                                        ),
                                        child: Text(
                                          tenantName!,
                                          style: const TextStyle(
                                            fontSize: 12,
                                            color: kBlack,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
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
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: kWhite,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: kBlack,
                                width: kBorderWidth,
                              ),
                            ),
                            child: Row(
                              children: [
                                const Text(
                                  '¥',
                                  style: TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.w700,
                                    color: kBlack,
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
                                      color: kBlack,
                                    ),
                                  ),
                                ),
                                IconButton(
                                  onPressed: () => _setAmount(0),
                                  style: TextButton.styleFrom(
                                    foregroundColor: kBlack,
                                  ),
                                  icon: const Icon(
                                    Icons.clear,
                                    color: Color.fromARGB(255, 60, 60, 60),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 2,
                            alignment: WrapAlignment.spaceBetween,
                            children: presets.map((v) {
                              final active = _currentAmount() == v;
                              return ChoiceChip(
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                                label: Text('¥${_fmt(v)}'),
                                selected: active,
                                showCheckmark: false,
                                backgroundColor: kYellow,
                                selectedColor: kBlack,
                                labelStyle: TextStyle(
                                  color: active ? kWhite : kBlack,
                                  fontWeight: FontWeight.w700,
                                ),
                                side: const BorderSide(color: kBlack, width: 3),
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

                    // ===== 開発用：決済完了画面へ遷移 =====
                    const SizedBox(height: 4),
                    // SizedBox(
                    //   width: double.infinity,
                    //   child: FilledButton.icon(
                    //     onPressed: _loading
                    //         ? null
                    //         : () {
                    //             if (tenantId == null || employeeId == null) {
                    //               ScaffoldMessenger.of(context).showSnackBar(
                    //                 const SnackBar(
                    //                   content: Text('スタッフ情報が不明です'),
                    //                 ),
                    //               );
                    //               return;
                    //             }
                    //             final amount = _currentAmount();
                    //             if (amount < 100) {
                    //               ScaffoldMessenger.of(context).showSnackBar(
                    //                 const SnackBar(
                    //                   content: Text('チップは100円から送ることができます'),
                    //                 ),
                    //               );
                    //               return;
                    //             }
                    //             Navigator.push(
                    //               context,
                    //               MaterialPageRoute(
                    //                 builder: (_) => TipCompletePage(
                    //                   tenantId: tenantId!,
                    //                   tenantName: tenantName ?? '店舗',
                    //                   employeeName: name,
                    //                   amount: amount,
                    //                 ),
                    //               ),
                    //             );
                    //           },
                    //     style: FilledButton.styleFrom(
                    //       backgroundColor: kWhite,
                    //       foregroundColor: kBlack,
                    //       shape: RoundedRectangleBorder(
                    //         borderRadius: BorderRadius.circular(12),
                    //         side: const BorderSide(
                    //           color: kBlack,
                    //           width: kBorderWidth,
                    //         ),
                    //       ),
                    //       padding: const EdgeInsets.symmetric(vertical: 14),
                    //     ),
                    //     icon: const Icon(Icons.volunteer_activism),
                    //     label: const Text('決済完了画面へ遷移'),
                    //   ),
                    // ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
      // 画面下部に常にボタンを設置
      bottomNavigationBar: SizedBox(
        height: 100, // ← ボトムバー全体の高さを指定
        child: BottomAppBar(
          color: kYellow,
          child: Padding(
            padding: const EdgeInsets.all(4.0), // ← ボタンが潰れないよう余白
            child: FilledButton.icon(
              onPressed: _loading ? null : _sendTip,
              style: FilledButton.styleFrom(
                backgroundColor: kWhite,
                foregroundColor: kBlack,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: const BorderSide(color: kBlack, width: kBorderWidth),
                ),
              ),
              icon: _loading
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: kBlack,
                      ),
                    )
                  : const Icon(Icons.volunteer_activism),
              label: _loading
                  ? const Text('処理中…')
                  : const Text(
                      'チップを贈る',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: kBlack,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 画面内テンキー（1–9 / 00 / 0 / ⌫）
class _AmountKeypad extends StatelessWidget {
  // デザイン定数（このクラス内でも統一）
  static const Color kBlack = Color(0xFF000000);
  static const Color kWhite = Color(0xFFFFFFFF);
  static const double kBorderWidth = 5.0;

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
        backgroundColor: kWhite,
        foregroundColor: kBlack,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        side: const BorderSide(color: kBlack, width: kBorderWidth),
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
        backgroundColor: kWhite,
        foregroundColor: kBlack,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        side: const BorderSide(color: kBlack, width: kBorderWidth),
        padding: const EdgeInsets.symmetric(vertical: 14),
      ),
      child: Icon(icon, size: 22),
    );
  }
}
