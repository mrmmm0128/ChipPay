import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:yourpay/endUser/public_store_page.dart';
import 'package:yourpay/endUser/utils/design.dart';

// ▼ 追加：アプリ内再生用
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';

class TipCompletePage extends StatefulWidget {
  final String tenantId;
  final String? tenantName;
  final int? amount;
  final String? employeeName;
  final String? uid;

  const TipCompletePage({
    super.key,
    required this.tenantId,
    this.tenantName,
    this.amount,
    this.employeeName,
    this.uid,
  });

  @override
  State<TipCompletePage> createState() => _TipCompletePageState();
}

class _TipCompletePageState extends State<TipCompletePage> {
  Future<_LinksGateResult>? _linksGateFuture;

  @override
  void initState() {
    super.initState();
    _linksGateFuture = _loadLinksGate();
  }

  Future<_LinksGateResult> _loadLinksGate() async {
    final String tid = widget.tenantId;
    final String? uid = widget.uid;

    final fs = FirebaseFirestore.instance;

    // 1) 読みやすいヘルパー
    Future<Map<String, dynamic>?> _read(DocumentReference ref) async {
      try {
        final snap = await ref.get();
        if (!snap.exists) return null;
        final data = snap.data();
        return (data is Map<String, dynamic>) ? data : null;
      } on FirebaseException catch (_) {
        // 読み取り権限がない/存在しないなどは黙って無視（公開ページ想定）
        return null;
      } catch (_) {
        return null;
      }
    }

    String _pickStr(List<dynamic> candidates) {
      for (final v in candidates) {
        if (v is String && v.trim().isNotEmpty) return v.trim();
      }
      return '';
    }

    String? _readPlan(Map<String, dynamic> m) {
      final sub = m['subscription'];
      if (sub is Map) {
        final p = sub['plan'];
        if (p is String && p.trim().isNotEmpty) return p.trim();
      }
      for (final k in const ['subscriptionPlan', 'plan', 'subscription_type']) {
        final v = m[k];
        if (v is String && v.trim().isNotEmpty) return v.trim();
      }
      return null;
    }

    String? _getThanksPhoto(Map<String, dynamic> m) {
      // c_perks.thanksPhotoUrl or top-level thanksPhotoUrl
      final perks = m['c_perks'];
      final fromPerks = (perks is Map) ? perks['thanksPhotoUrl'] : null;
      return _pickStr([fromPerks, m['thanksPhotoUrl']]);
    }

    String? _getThanksVideo(Map<String, dynamic> m) {
      // c_perks.thanksVideoUrl or top-level thanksVideoUrl
      final perks = m['storagePath'];

      return perks;
    }

    String? _getGoogleReview(Map<String, dynamic> m) {
      // subscription.extras.googleReviewUrl → top-level googleReviewUrl
      final url = m['c_perks.reviewUrl'];

      return url;
    }

    String? _getLineOfficial(Map<String, dynamic> m) {
      final url = m['c_perks.lineUrl'];
      return url;
    }

    // 2) 候補ドキュメントを全部読む（取れるものだけ）
    Map<String, dynamic> userTenant = const {};
    Map<String, dynamic> publicTenant = const {};
    Map<String, dynamic> publicThanks = const {};
    Map<String, dynamic> publicThanksStaff = const {};

    if (uid != null && uid.isNotEmpty) {
      userTenant =
          await _read(fs.collection(uid).doc(tid)) ?? const <String, dynamic>{};
    }
    publicTenant =
        await _read(fs.collection('tenants').doc(tid)) ??
        const <String, dynamic>{};

    // アップローダが publicThanks にも保存しているのでここも見る
    publicThanks =
        await _read(fs.collection('publicThanks').doc(tid)) ??
        const <String, dynamic>{};

    publicThanksStaff =
        await _read(
          fs
              .collection('publicThanks')
              .doc(tid)
              .collection("staff")
              .doc(widget.employeeName)
              .collection("videos")
              .doc(),
        ) ??
        const <String, dynamic>{};

    // 3) マージ方針
    // - プランや extras は「userTenant → publicTenant」の優先で採用
    // - 写真/動画は「userTenant → publicThanks → publicTenant」の優先で採用
    //   （アップロード実装に合わせて publicThanks を中間に挟む）
    final planRaw = _readPlan(userTenant) ?? _readPlan(publicTenant) ?? '';
    final plan = planRaw.toUpperCase().trim();
    final isSubC = plan == 'C';

    final googleReviewUrl = _pickStr([
      _getGoogleReview(userTenant),
      _getGoogleReview(publicTenant),
    ]);
    final lineOfficialUrl = _pickStr([
      _getLineOfficial(userTenant),
      _getLineOfficial(publicTenant),
    ]);

    final thanksPhotoUrl = _pickStr([
      _getThanksPhoto(userTenant),
      _getThanksPhoto(publicThanks),
      _getThanksPhoto(publicTenant),
    ]);
    final thanksVideoUrl = _pickStr([
      _getThanksVideo(userTenant),
      _getThanksVideo(publicThanksStaff),
    ]);

    return _LinksGateResult(
      isSubC: isSubC,
      googleReviewUrl: googleReviewUrl,
      lineOfficialUrl: lineOfficialUrl,
      thanksVideoUrl: thanksVideoUrl,
      thanksPhotoUrl: thanksPhotoUrl,
    );
  }

  void _navigatePublicStorePage() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const PublicStorePage(),
        settings: RouteSettings(
          arguments: {
            'tenantId': widget.tenantId,
            'tenantName': widget.tenantName,
            "uid": widget.uid,
          },
        ),
      ),
    );
  }

  Future<void> _openStoreTipBottomSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppPalette.yellow,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _StoreTipBottomSheet(
        tenantId: widget.tenantId,
        tenantName: widget.tenantName,
      ),
    );
  }

  Future<void> _openUrl(String url) async {
    if (url.isEmpty) return;
    await launchUrlString(url, mode: LaunchMode.externalApplication);
  }

  // ▼ 追加：黒枠タップでモーダル再生
  Future<void> _openThanksVideo(String url) async {
    if (url.isEmpty) return;

    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        final videoCtrl = VideoPlayerController.networkUrl(Uri.parse(url));
        final chewieCtrl = ChewieController(
          videoPlayerController: videoCtrl,
          autoPlay: true,
          looping: false,
          allowMuting: true,
          allowPlaybackSpeedChanging: true,
          materialProgressColors: ChewieProgressColors(),
        );

        return Dialog(
          insetPadding: const EdgeInsets.all(16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Chewie(controller: chewieCtrl),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final storeLabel = widget.tenantName ?? tr('success_page.store');

    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset(
                  'assets/endUser/checked.png',
                  width: 80,
                  height: 80,
                ),
                const SizedBox(height: 12),
                Text(tr("success_page.success"), style: AppTypography.label()),
                if (widget.employeeName != null || widget.amount != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    [
                      if (widget.employeeName != null)
                        tr(
                          'success_page.for',
                          namedArgs: {"Name": widget.employeeName ?? ''},
                        ),
                      if (widget.amount != null)
                        tr(
                          "success_page.amount",
                          namedArgs: {
                            "Amount": widget.amount?.toString() ?? '',
                          },
                        ),
                    ].join(' / '),
                    style: AppTypography.body(),
                  ),
                ],

                const SizedBox(height: 20),

                // ▼ 「動画のみ」表示ブロック
                FutureBuilder<_LinksGateResult>(
                  future: _linksGateFuture,
                  builder: (context, snap) {
                    if (snap.connectionState == ConnectionState.waiting) {
                      return const SizedBox(
                        height: 24,
                        width: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      );
                    }
                    if (!snap.hasData) {
                      return const SizedBox.shrink();
                    }

                    final r = snap.data!;
                    final hasVideo =
                        (r.thanksVideoUrl != null &&
                        r.thanksVideoUrl!.isNotEmpty);

                    // Cプラン & 動画URLあり → 黒枠+再生ボタン
                    if (r.isSubC && hasVideo) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            tr('success_page.thanks_from_store'),
                            style: AppTypography.body(),
                            textAlign: TextAlign.left,
                          ),
                          const SizedBox(height: 8),
                          GestureDetector(
                            onTap: () => _openThanksVideo(r.thanksVideoUrl!),
                            child: AspectRatio(
                              aspectRatio: 16 / 9,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: Colors.black,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Stack(
                                  alignment: Alignment.center,
                                  children: const [
                                    // 中央の再生ボタン
                                    Icon(
                                      Icons.play_circle_fill,
                                      color: Colors.white,
                                      size: 72,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          const Divider(),
                        ],
                      );
                    }

                    // それ以外（A/Bプランや動画無し）はデフォ画像を表示
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // デフォルト画像（仮パス）
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.asset(
                            'assets/images/thanks_placeholder.png',
                            fit: BoxFit.cover,
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Divider(),
                      ],
                    );
                  },
                ),

                const SizedBox(height: 12),

                // ① お店にチップを送る（ボトムシート）
                _YellowActionButton(
                  label: tr(
                    'stripe.tip_for_store1',
                    namedArgs: {'tenantName': storeLabel},
                  ),
                  onPressed: _openStoreTipBottomSheet,
                ),
                const SizedBox(height: 8),

                // ② 他のスタッフにチップを送る（店舗ページへ）
                _YellowActionButton(
                  label: tr('success_page.initiate1'),
                  onPressed: _navigatePublicStorePage,
                ),

                const SizedBox(height: 24),
                const Divider(),

                // ▼（従来どおり）サブスクC限定：Googleレビュー / LINE
                FutureBuilder<_LinksGateResult>(
                  future: _linksGateFuture,
                  builder: (context, snap) {
                    if (snap.connectionState == ConnectionState.waiting) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: SizedBox(
                          height: 24,
                          width: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      );
                    }
                    if (snap.hasError || !snap.hasData) {
                      return const SizedBox.shrink();
                    }
                    final r = snap.data!;
                    if (!r.isSubC) return const SizedBox.shrink();

                    final hasReview =
                        (r.googleReviewUrl != null &&
                        r.googleReviewUrl!.isNotEmpty);
                    final hasLine =
                        (r.lineOfficialUrl != null &&
                        r.lineOfficialUrl!.isNotEmpty);
                    if (!hasReview && !hasLine) return const SizedBox.shrink();

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(height: 16),
                        Text(
                          tr("sucess_page.initiate2"),
                          style: Theme.of(context).textTheme.titleMedium,
                          textAlign: TextAlign.left,
                        ),
                        const SizedBox(height: 8),
                        if (hasReview)
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              icon: const Icon(Icons.reviews_outlined),
                              label: Text(tr('sucess_page.initiate21')),
                              onPressed: () => _openUrl(r.googleReviewUrl!),
                            ),
                          ),
                        if (hasReview && hasLine) const SizedBox(height: 8),
                        if (hasLine)
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              icon: const Icon(Icons.chat_bubble_outline),
                              label: Text(tr("sucess_page.initiate22")),
                              onPressed: () => _openUrl(r.lineOfficialUrl!),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ※ 既存の _LinksGateResult を使っている前提です。
//   isSubC / googleReviewUrl / lineOfficialUrl / thanksVideoUrl を持つクラス。
// class _LinksGateResult { ... }

/// ここで “Cプラン判定 + 特典リンク + 感謝の写真/動画” をまとめて返す
class _LinksGateResult {
  final bool isSubC;
  final String? googleReviewUrl;
  final String? lineOfficialUrl;
  final String? thanksPhotoUrl;
  final String? thanksVideoUrl;
  _LinksGateResult({
    required this.isSubC,
    this.googleReviewUrl,
    this.lineOfficialUrl,
    this.thanksPhotoUrl,
    this.thanksVideoUrl,
  });
}

class _StoreTipBottomSheet extends StatefulWidget {
  final String tenantId;
  final String? tenantName;

  const _StoreTipBottomSheet({required this.tenantId, this.tenantName});

  @override
  State<_StoreTipBottomSheet> createState() => _StoreTipBottomSheetState();
}

class _StoreTipBottomSheetState extends State<_StoreTipBottomSheet> {
  int _amount = 500; // デフォルト金額
  bool _loading = false;

  static const int _maxStoreTip = 1000000; // 最大金額（100万円）
  final _presets = const [1000, 3000, 5000, 10000];

  void _setAmount(int value) {
    setState(() => _amount = value.clamp(0, _maxStoreTip));
  }

  void _appendDigit(int digit) {
    setState(() => _amount = (_amount * 10 + digit).clamp(0, _maxStoreTip));
  }

  void _appendDoubleZero() {
    if (_amount > 0) {
      setState(() => _amount = (_amount * 100).clamp(0, _maxStoreTip));
    }
  }

  void _backspace() {
    setState(() => _amount = _amount ~/ 10);
  }

  Future<void> _goStripe() async {
    if (_amount <= 0 || _amount > _maxStoreTip) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr('stripe.attention'))));
      return;
    }

    setState(() => _loading = true);
    try {
      final callable = FirebaseFunctions.instance.httpsCallable(
        'createStoreTipSessionPublic',
      );
      final response = await callable.call({
        'tenantId': widget.tenantId,
        'amount': _amount,
        'memo': 'Tip to store ${widget.tenantName ?? ''}',
      });
      final data = Map<String, dynamic>.from(response.data as Map);
      final checkoutUrl = data['checkoutUrl'] as String?;
      if (checkoutUrl != null && checkoutUrl.isNotEmpty) {
        Navigator.of(context).pop(); // ボトムシートを閉じる
        await launchUrlString(
          checkoutUrl,
          mode: LaunchMode.externalApplication,
        );
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(tr('stripe.miss_URL'))));
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr("stripe.error", args: [e.toString()]))),
      );
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // タイトル
          Row(
            children: [
              const Icon(Icons.storefront, color: Colors.black87),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.tenantName == null
                      ? tr("stripe.tip_for_store")
                      : tr(
                          "stripe.tip_for_store1",
                          namedArgs: {"tenantName": ?widget.tenantName},
                        ),
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: Colors.black87,
                  ),
                ),
              ),
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // 金額表示
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: AppPalette.border,
                width: AppDims.border,
              ),
            ),
            child: Row(
              children: [
                const Text(
                  '¥',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '$_amount',
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      color: Colors.black87,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: () => _setAmount(0),
                  icon: const Icon(Icons.clear),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // プリセット
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _presets.map((preset) {
              final isSelected = _amount == preset;
              return ChoiceChip(
                side: BorderSide(
                  color: AppPalette.border,
                  width: AppDims.border,
                ),
                showCheckmark: false,
                label: Text('¥$preset'),
                selected: isSelected,
                onSelected: (_) => _setAmount(preset),
                selectedColor: AppPalette.black,
                backgroundColor: AppPalette.white,
                labelStyle: TextStyle(
                  color: isSelected ? AppPalette.white : AppPalette.black,
                  fontWeight: FontWeight.w600,
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 12),
          // キーパッド
          _Keypad(
            onTapDigit: _appendDigit,
            onTapDoubleZero: _appendDoubleZero,
            onBackspace: _backspace,
          ),
          const SizedBox(height: 12),
          // フッター
          Row(
            children: [
              Flexible(
                flex: 1,
                child: _YellowActionButton2(
                  label: tr('button.cancel'),
                  onPressed: _loading ? null : () => Navigator.pop(context),
                  color: AppPalette.white,
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                flex: 2,
                child: _YellowActionButton(
                  label: tr('button.send_tip'),
                  onPressed: _loading ? null : _goStripe,
                  color: AppPalette.white,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// テンキー
class _Keypad extends StatelessWidget {
  final void Function(int d) onTapDigit;
  final VoidCallback onTapDoubleZero;
  final VoidCallback onBackspace;
  const _Keypad({
    required this.onTapDigit,
    required this.onTapDoubleZero,
    required this.onBackspace,
  });

  Widget _btn(BuildContext ctx, String label, VoidCallback onPressed) {
    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppPalette.white,
        foregroundColor: AppPalette.black,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppDims.radius),
        ),
        side: BorderSide(color: AppPalette.border, width: AppDims.border),
        padding: const EdgeInsets.symmetric(vertical: 14),
      ),
      onPressed: onPressed,
      child: Text(label, style: const TextStyle(fontSize: 18)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(child: _btn(context, '1', () => onTapDigit(1))),
            const SizedBox(width: 8),
            Expanded(child: _btn(context, '2', () => onTapDigit(2))),
            const SizedBox(width: 8),
            Expanded(child: _btn(context, '3', () => onTapDigit(3))),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: _btn(context, '4', () => onTapDigit(4))),
            const SizedBox(width: 8),
            Expanded(child: _btn(context, '5', () => onTapDigit(5))),
            const SizedBox(width: 8),
            Expanded(child: _btn(context, '6', () => onTapDigit(6))),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: _btn(context, '7', () => onTapDigit(7))),
            const SizedBox(width: 8),
            Expanded(child: _btn(context, '8', () => onTapDigit(8))),
            const SizedBox(width: 8),
            Expanded(child: _btn(context, '9', () => onTapDigit(9))),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: _btn(context, '00', onTapDoubleZero)),
            const SizedBox(width: 8),
            Expanded(child: _btn(context, '0', () => onTapDigit(0))),
            const SizedBox(width: 8),
            Expanded(
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppPalette.white,
                  foregroundColor: AppPalette.black,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppDims.radius),
                  ),
                  side: BorderSide(
                    color: AppPalette.border,
                    width: AppDims.border,
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: onBackspace,
                child: const Icon(Icons.backspace_outlined, size: 18),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 黄色×黒の大ボタン（色は任意で上書き可）
/// テキストがオーバーフローしそうな場合は自動で縮小して収めます。
class _YellowActionButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;

  /// 背景色。未指定(null)なら AppPalette.yellow を使用
  final Color? color;

  const _YellowActionButton({
    required this.label,
    this.icon,
    this.onPressed,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final bg = color ?? AppPalette.yellow;

    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(AppDims.radius),
      clipBehavior: Clip.antiAlias, // 角丸内にリップルをクリップ
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(AppDims.radius),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppDims.radius),
            border: Border.all(color: AppPalette.border, width: AppDims.border),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, color: AppPalette.black),
                const SizedBox(width: 8),
              ],
              // ★ ここがポイント：Flexible + FittedBox(scaleDown)
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown, // 収まらない時だけ縮小
                  alignment: Alignment.center,
                  child: Text(
                    label,
                    maxLines: 1,
                    // overflow は不要（縮小で収めるため）。保険で付けたいなら TextOverflow.ellipsis を。
                    style: AppTypography.label(color: AppPalette.black),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 黄色×黒の大ボタン（色は任意で上書き可）
/// テキストがオーバーフローしそうな場合は自動で縮小して収めます。
class _YellowActionButton2 extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;

  /// 背景色。未指定(null)なら AppPalette.yellow を使用
  final Color? color;

  const _YellowActionButton2({
    required this.label,
    this.icon,
    this.onPressed,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final bg = color ?? AppPalette.yellow;

    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(AppDims.radius),
      clipBehavior: Clip.antiAlias, // 角丸内にリップルをクリップ
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(AppDims.radius),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppDims.radius),
            border: Border.all(color: AppPalette.border, width: AppDims.border),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, color: AppPalette.black),
                const SizedBox(width: 8),
              ],
              // ★ ここがポイント：Flexible + FittedBox(scaleDown)
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown, // 収まらない時だけ縮小
                  alignment: Alignment.center,
                  child: Text(
                    label,
                    maxLines: 1,
                    // overflow は不要（縮小で収めるため）。保険で付けたいなら TextOverflow.ellipsis を。
                    style: AppTypography.label2(color: AppPalette.black),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
