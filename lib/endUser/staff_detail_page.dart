import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:yourpay/endUser/tip_complete_page.dart';
import 'package:yourpay/endUser/tip_waiting_page.dart';
import 'package:yourpay/endUser/utils/design.dart';

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
  String? uid;

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
      uid = args["uid"] as String?;
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
    // すでに埋まっていれば二度目は何もしない
    if (tenantId != null && employeeId != null) return;

    final uri = Uri.base;

    // 1) 通常のクエリ（?key=value）
    final qp1 = uri.queryParameters;

    // 2) ハッシュルーター（/#/store/staff?key=value）内のクエリ
    //    例: fragment = "/store/staff?u=xxx&t=yyy&e=zzz&a=1000"
    final frag = uri.fragment;
    Map<String, String> qp2 = {};
    final qIndex = frag.indexOf('?');
    if (qIndex >= 0 && qIndex < frag.length - 1) {
      qp2 = Uri.splitQueryString(frag.substring(qIndex + 1));
    }

    // 3) 予防的に、ハッシュ直前にクエリがある稀パターンも拾う（/#/?k=v）
    //    一般的ではないが念のためマージ
    final merged = <String, String>{};
    merged.addAll(qp1);
    merged.addAll(qp2);

    // 複数キー候補のうち最初に見つかった値を返す
    String? pickAny(List<String> keys) {
      for (final k in keys) {
        final v = merged[k];
        if (v != null && v.isNotEmpty) return v;
      }
      return null;
    }

    final u = pickAny(['u', 'uid', 'user']); // 送信元ユーザーID（任意）
    final t = pickAny(['t', 'tenantId']); // テナントID
    final e = pickAny(['e', 'employeeId']); // 従業員ID
    final a = pickAny(['a', 'amount']); // 初期金額（任意）

    // 既存の別名キーも継続サポート
    name = name ?? pickAny(['name', 'n']);
    email = email ?? pickAny(['email', 'mail']);
    photoUrl = photoUrl ?? pickAny(['photoUrl', 'p']);
    tenantName = tenantName ?? pickAny(['tenantName', 'store']);

    // 反映
    tenantId = tenantId ?? t;
    employeeId = employeeId ?? e;

    // deep link に含まれる uid を保持したい場合は専用フィールドへ（例）
    // 既にサインイン済みの uid を上書きしたくないので別変数に格納推奨
    if (u != null) {
      // 例: refUid / inviterUid / deepLinkUid など、プロジェクトに合わせて命名
      uid = u; // <- クラスに String? deepLinkUid; を用意しておく
    }

    if (a != null) {
      _amountCtrl.text = a;
    }

    if (mounted) setState(() {});
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
          .collection(uid!)
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
          .collection(uid!)
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
      ).showSnackBar(SnackBar(content: Text(tr('validation.tip.min'))));
      return;
    }
    if (amount > _maxAmount) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr('validation.tip.max'))));
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
            uid: uid,
          ),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('stripe.error', args: [e.toString()]))),
      );
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
      color: AppPalette.white,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: AppPalette.black, width: AppDims.border),
      boxShadow: [
        BoxShadow(
          color: AppPalette.black.withOpacity(0.06),
          blurRadius: 8,
          offset: const Offset(0, 3),
        ),
      ],
    );

    return Scaffold(
      backgroundColor: AppPalette.yellow,
      appBar: AppBar(
        backgroundColor: Colors.transparent, // ← 透明
        surfaceTintColor: Colors.transparent, // M3 のティントも無効化
        shadowColor: Colors.transparent, // 念のため影も消す
        foregroundColor: AppPalette.black,
        toolbarHeight: 30,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(0, 4, 0, 0),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight - 40,
                ),
                child: Column(
                  children: [
                    Container(
                      padding: EdgeInsets.fromLTRB(12, 0, 12, 0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // ===== プロフィールカード =====
                          Column(
                            children: [
                              Container(
                                width: 72,
                                height: 72,
                                decoration: BoxDecoration(
                                  color: AppPalette.white,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: AppPalette.black,
                                    width: AppDims.border2,
                                  ),
                                ),
                                child: CircleAvatar(
                                  backgroundColor: AppPalette.white,
                                  radius: 36,
                                  backgroundImage:
                                      (photoUrl != null && photoUrl!.isNotEmpty)
                                      ? NetworkImage(photoUrl!)
                                      : null,
                                  child: (photoUrl == null || photoUrl!.isEmpty)
                                      ? const Icon(
                                          Icons.person,
                                          size: 36,
                                          color: AppPalette.black,
                                        )
                                      : null,
                                ),
                              ),
                              Text(title, style: AppTypography.label()),
                            ],
                          ),

                          const SizedBox(height: 14),

                          // ===== 金額カード（表示＋プリセット）=====
                          Container(
                            decoration: cardDecoration,
                            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Container(
                                  padding: EdgeInsets.symmetric(horizontal: 12),
                                  child: Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(
                                        tr("validation.value"),
                                        style: AppTypography.body(),
                                      ),
                                      TextButton.icon(
                                        style: TextButton.styleFrom(
                                          foregroundColor: AppPalette.black,
                                          padding:
                                              EdgeInsets.zero, // 内部のpaddingをゼロに
                                          minimumSize: Size(
                                            0,
                                            0,
                                          ), // サイズ制約も外す（必要なら）
                                          tapTargetSize: MaterialTapTargetSize
                                              .shrinkWrap, // タップ領域も縮める
                                        ),
                                        onPressed: () => _setAmount(0),
                                        icon: const Icon(
                                          Icons.clear,
                                          size: 20,
                                        ), // アイコンサイズを明示
                                        label: Text(
                                          tr("validation.clear"),
                                          style: AppTypography.body(),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppPalette.white,
                                    borderRadius: BorderRadius.circular(18),
                                    border: Border.all(
                                      color: AppPalette.black,
                                      width: AppDims.border,
                                    ),
                                  ),
                                  child: Container(
                                    padding: EdgeInsets.symmetric(
                                      vertical: 8,
                                      horizontal: 12,
                                    ),
                                    child: Row(
                                      children: [
                                        Text(
                                          '¥',
                                          style: TextStyle(
                                            fontSize: 30,
                                            fontFamily: 'LINEseed',
                                            fontWeight: FontWeight.w700,
                                            color: AppPalette.black,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            _fmt(_currentAmount()),
                                            textAlign: TextAlign.right,
                                            style: TextStyle(
                                              fontFamily: 'LINEseed',
                                              fontSize: 28,
                                              color: AppPalette.textPrimary,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 2,
                                  alignment: WrapAlignment.spaceBetween,
                                  children: presets.map((v) {
                                    final active = _currentAmount() == v;
                                    return ChoiceChip(
                                      materialTapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                      label: Text(
                                        '¥${_fmt(v)}',
                                        style: AppTypography.small(),
                                      ),
                                      selected: active,
                                      showCheckmark: false,
                                      side: BorderSide(
                                        width: 0,
                                        color: AppPalette.yellow,
                                      ),
                                      backgroundColor: AppPalette.yellow,
                                      selectedColor: AppPalette.black,
                                      labelStyle: TextStyle(
                                        color: active
                                            ? AppPalette.white
                                            : AppPalette.black,
                                        fontWeight: FontWeight.w700,
                                      ),
                                      onSelected: (_) => _setAmount(v),
                                      visualDensity: const VisualDensity(
                                        vertical: -2,
                                      ), // 👈 ここを追加
                                    );
                                  }).toList(),
                                ),
                              ],
                            ),
                          ),
                          SizedBox(height: 8),

                          SizedBox(
                            height: 80,
                            child: Padding(
                              padding: const EdgeInsets.all(
                                0,
                              ), // ← ボタンが潰れないよう余白
                              child: FilledButton.icon(
                                onPressed: _loading ? null : _sendTip,
                                style: FilledButton.styleFrom(
                                  backgroundColor: AppPalette.white,
                                  foregroundColor: AppPalette.black,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(18),
                                    side: const BorderSide(
                                      color: AppPalette.black,
                                      width: AppDims.border,
                                    ),
                                  ),
                                ),
                                label: _loading
                                    ? Text(tr('status.processing'))
                                    : Text(
                                        tr("button.send_tip"),
                                        style: AppTypography.label(),
                                      ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 14),

                    // ===== キーパッドカード =====
                    Column(
                      children: [
                        Column(
                          children: [
                            Container(
                              decoration: BoxDecoration(
                                color: AppPalette.white,
                                borderRadius: BorderRadius.only(
                                  topLeft: Radius.circular(AppDims.radius),
                                  topRight: Radius.circular(AppDims.radius),
                                ),
                              ),
                              padding: const EdgeInsets.symmetric(
                                vertical: 12,
                                horizontal: 12,
                              ),
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
                          ],
                        ),
                        // ===== 開発用：決済完了画面へ遷移 =====
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: _loading
                                ? null
                                : () {
                                    if (tenantId == null ||
                                        employeeId == null) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text('スタッフ情報が不明です'),
                                        ),
                                      );
                                      return;
                                    }
                                    final amount = _currentAmount();
                                    if (amount < 100) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text('チップは100円から送ることができます'),
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
                            style: FilledButton.styleFrom(
                              backgroundColor: AppPalette.white,
                              foregroundColor: AppPalette.black,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                                side: const BorderSide(
                                  color: AppPalette.black,
                                  width: AppDims.border,
                                ),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                            icon: const Icon(Icons.volunteer_activism),
                            label: const Text('決済完了画面へ遷移'),
                          ),
                        ),
                      ],
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
        backgroundColor: AppPalette.yellow,
        foregroundColor: AppPalette.black,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        side: const BorderSide(color: AppPalette.black, width: AppDims.border),
        padding: const EdgeInsets.symmetric(vertical: 14),
        textStyle: AppTypography.label(),
      ),
      child: Text(label),
    );
  }

  Widget _iconBtn(IconData icon, VoidCallback onPressed) {
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        elevation: 0,
        backgroundColor: AppPalette.yellow,
        foregroundColor: AppPalette.black,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        side: const BorderSide(color: AppPalette.black, width: AppDims.border),
        padding: const EdgeInsets.symmetric(vertical: 14),
      ),
      child: Icon(icon, size: 22),
    );
  }
}
