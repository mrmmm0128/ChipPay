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

enum _CommentAction { cancel, skip, ok }

class _StaffDetailPageState extends State<StaffDetailPage> {
  String? tenantId;
  String? employeeId;
  String? name;
  String? email;
  String? photoUrl;
  String? tenantName;
  String? uid;

  final _amountCtrl = TextEditingController(text: '0'); // デフォルト
  bool _loading = false;

  // ★追加: 送金者コメント
  final _messageCtrl = TextEditingController();
  String? _senderMessage;
  // 最大文字数はお好みで
  static const int _maxMessageLength = 200;

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
    _messageCtrl.dispose();
    super.dispose();
  }

  int _currentAmount() {
    final v = int.tryParse(_amountCtrl.text) ?? 0;
    return v.clamp(0, _maxAmount);
  }

  // ★追加: メッセージ入力ダイアログ
  Future<void> _editSenderMessage() async {
    _messageCtrl.text = _senderMessage ?? '';
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('メッセージを添える'),
        content: TextField(
          controller: _messageCtrl,
          maxLines: 4,
          maxLength: _maxMessageLength,
          decoration: const InputDecoration(
            hintText: '（任意）スタッフへ一言メッセージ',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              _messageCtrl.clear();
              Navigator.pop(context, true);
            },
            child: const Text('クリア'),
          ),
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
    if (saved == true) {
      setState(
        () => _senderMessage = _messageCtrl.text.trim().isEmpty
            ? null
            : _messageCtrl.text.trim(),
      );
    }
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

  // ▼ StaffDetailPageState 内のどこか（_sendTip()の上あたり）に追加
  Future<void> _promptAndSendTip() async {
    // 1) 前提チェック & 金額バリデーション
    if (tenantId == null || employeeId == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('スタッフ情報が不明です')));
      return;
    }
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

    // 2) コメント入力ポップアップを必ず表示
    _messageCtrl.text = _senderMessage ?? '';
    final result = await showDialog<_CommentAction>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Theme(
        data: Theme.of(context).copyWith(
          dialogBackgroundColor: AppPalette.white,
          colorScheme: Theme.of(context).colorScheme.copyWith(
            primary: AppPalette.black,
            surface: AppPalette.white,
            onSurface: AppPalette.black,
          ),
          textButtonTheme: TextButtonThemeData(
            style: TextButton.styleFrom(
              foregroundColor: AppPalette.black,
              textStyle: AppTypography.body(),
            ),
          ),
          outlinedButtonTheme: OutlinedButtonThemeData(
            style: OutlinedButton.styleFrom(
              foregroundColor: AppPalette.black,
              backgroundColor: AppPalette.white,
              side: BorderSide(color: AppPalette.black, width: AppDims.border),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              textStyle: AppTypography.label(),
            ),
          ),
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(
              backgroundColor: AppPalette.black,
              foregroundColor: AppPalette.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              textStyle: AppTypography.label(),
            ),
          ),
        ),
        child: AlertDialog(
          backgroundColor: AppPalette.white,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: AppPalette.black, width: AppDims.border),
          ),
          title: Text(
            'メッセージを添えますか？',
            style: AppTypography.label(color: AppPalette.black),
          ),
          content: TextField(
            controller: _messageCtrl,
            maxLines: 4,
            maxLength: _maxMessageLength,
            style: AppTypography.body(color: AppPalette.black),
            decoration: InputDecoration(
              hintText: '（任意）スタッフへ一言メッセージ',
              hintStyle: AppTypography.small(color: AppPalette.textSecondary),
              filled: true,
              fillColor: AppPalette.white,
              contentPadding: const EdgeInsets.all(12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: AppPalette.black,
                  width: AppDims.border,
                ),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: AppPalette.black,
                  width: AppDims.border,
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: AppPalette.black,
                  width: AppDims.border2,
                ),
              ),
            ),
          ),
          actions: [
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () =>
                        Navigator.pop(context, _CommentAction.cancel),
                    child: const Text('戻る'),
                  ),
                ),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () =>
                        Navigator.pop(context, _CommentAction.skip),
                    child: const Text('スキップ'),
                  ),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, _CommentAction.ok),
                  child: const Text('決済へ進む'),
                ),
              ],
            ),
          ],
        ),
      ),
    );

    // 3) ダイアログ結果で分岐
    if (!mounted || result == null || result == _CommentAction.cancel) return;

    // 必須にしたい場合は、ここで _messageCtrl.text が空ならエラー表示して return するだけでOK
    // if (result == _CommentAction.ok && _messageCtrl.text.trim().isEmpty) { ... return; }

    // スキップ→空文字、OK→入力を採用
    if (result == _CommentAction.skip) {
      _senderMessage = null;
    } else {
      final msg = _messageCtrl.text.trim();
      _senderMessage = msg.isEmpty ? null : msg;
    }

    // 4) そのまま送信処理へ
    await _sendTip();
  }

  // ダイアログの戻り値

  Future<void> _ensureAnonSignIn() async {
    final auth = FirebaseAuth.instance;
    if (auth.currentUser == null) {
      await auth.signInAnonymously();
    }
  }

  // ② 送信処理にコメント同梱
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
        // ★追加: 送金者のコメントを一緒に送る
        'payerMessage': _senderMessage ?? '',
      });

      final data = Map<String, dynamic>.from(result.data as Map);
      final checkoutUrl = data['checkoutUrl'] as String;
      final sessionId = data['sessionId'] as String;

      await launchUrlString(
        checkoutUrl,
        mode: LaunchMode.platformDefault,
        webOnlyWindowName: '_self',
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
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        foregroundColor: AppPalette.black,
        toolbarHeight: 30,
        elevation: 0,
        scrolledUnderElevation: 0,
        actions: [
          FilledButton.icon(
            onPressed: _loading
                ? null
                : () {
                    if (tenantId == null || employeeId == null) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('スタッフ情報が不明です')),
                      );
                      return;
                    }
                    final amount = _currentAmount();
                    if (amount < 100) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('チップは100円から送ることができます')),
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
                          uid: uid,
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
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),

            label: const Text('開発用'),
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 画面が小さい時は少しだけコンパクトに
            final compact = constraints.maxHeight < 720;
            final avatar = compact ? 56.0 : 72.0;
            final amountFs = compact ? 24.0 : 28.0;
            final yenFs = compact ? 26.0 : 30.0;
            final sendBtnH = compact ? 64.0 : 80.0;

            return Column(
              children: [
                // ===== 上段（プロフィール・金額・送信）: 内容に合わせて高さ確保 =====
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // プロフィール
                      Column(
                        children: [
                          Container(
                            width: avatar,
                            height: avatar,
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
                              radius: avatar / 2,
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
                          const SizedBox(height: 6),
                          Text(title, style: AppTypography.label()),
                        ],
                      ),

                      const SizedBox(height: 10),

                      // 金額カード
                      Container(
                        decoration: cardDecoration,
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
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
                                      padding: EdgeInsets.zero,
                                      minimumSize: const Size(0, 0),
                                      tapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                    ),
                                    onPressed: () => _setAmount(0),
                                    icon: const Icon(Icons.clear, size: 20),
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
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                  horizontal: 12,
                                ),
                                child: Row(
                                  children: [
                                    Text(
                                      '¥',
                                      style: TextStyle(
                                        fontSize: yenFs,
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
                                          fontSize: amountFs,
                                          color: AppPalette.textPrimary,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Wrap(
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
                                        side: const BorderSide(
                                          width: 0,
                                          color: AppPalette.yellow,
                                        ),
                                        backgroundColor: AppPalette.yellow,
                                        selectedColor: AppPalette.yellow,
                                        labelStyle: TextStyle(
                                          color: AppPalette.black,
                                          fontWeight: FontWeight.w700,
                                        ),
                                        onSelected: (_) => _setAmount(v),
                                        visualDensity: const VisualDensity(
                                          vertical: -2,
                                          horizontal: 3,
                                        ),
                                      );
                                    }).toList(),
                                  ),
                                ),
                                const SizedBox(width: 10),
                              ],
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 8),

                      SizedBox(
                        height: sendBtnH,
                        child: FilledButton.icon(
                          onPressed: _loading ? null : _promptAndSendTip,
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
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                // ===== 下段（テンキー＋開発ボタン）: 余り全てを占有 =====
                Expanded(
                  child: Container(
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.only(
                        topLeft: Radius.circular(AppDims.radius),
                        topRight: Radius.circular(AppDims.radius),
                      ),
                    ),
                    padding: const EdgeInsets.symmetric(
                      vertical: 12,
                      horizontal: 12,
                    ),
                    child: Column(
                      children: [
                        // テンキーは残り高さにフィット
                        Expanded(
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
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 画面内テンキー（1–9 / 00 / 0 / ⌫）
/// 利用可能な高さから childAspectRatio を自動計算して 3×4 を必ず収める
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
    const cols = 3;
    const rows = 4;
    const mainSpacing = 8.0; // 縦方向間隔
    const crossSpacing = 8.0; // 横方向間隔

    final buttons = <Widget>[
      for (var i = 1; i <= 9; i++) _numBtn('$i', () => onTapDigit(i)),
      _numBtn('00', onTapDoubleZero),
      _numBtn('0', () => onTapDigit(0)),
      _iconBtn(Icons.backspace_outlined, onBackspace),
    ];

    return LayoutBuilder(
      builder: (context, c) {
        final itemW = (c.maxWidth - (cols - 1) * crossSpacing) / cols;
        final itemH = (c.maxHeight - (rows - 1) * mainSpacing) / rows;
        final ratio = itemW / itemH; // ← これで4行がちょうど入る

        return GridView.count(
          crossAxisCount: cols,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: mainSpacing,
          crossAxisSpacing: crossSpacing,
          childAspectRatio: ratio,
          children: buttons,
        );
      },
    );
  }

  Widget _numBtn(String label, VoidCallback onPressed) => ElevatedButton(
    onPressed: onPressed,
    style: ElevatedButton.styleFrom(
      elevation: 0,
      backgroundColor: AppPalette.yellow,
      foregroundColor: AppPalette.black,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      side: const BorderSide(color: AppPalette.black, width: AppDims.border),
      padding: const EdgeInsets.symmetric(vertical: 10),
      textStyle: AppTypography.label(),
    ),
    child: Text(label),
  );

  Widget _iconBtn(IconData icon, VoidCallback onPressed) => ElevatedButton(
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
