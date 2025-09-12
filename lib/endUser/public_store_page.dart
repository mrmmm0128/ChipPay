import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:yourpay/endUser/utils/design.dart';

/// 黒フチ × 黄色の“縁取りテキスト”
class StrokeText extends StatelessWidget {
  final String text;
  final TextStyle style;
  final double strokeWidth;
  final Color strokeColor;
  final Color fillColor;

  const StrokeText(
    this.text, {
    super.key,
    required this.style,
    this.strokeWidth = 0.5,
    this.strokeColor = AppPalette.black,
    this.fillColor = AppPalette.yellow,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // 黒フチ
        Text(
          text,
          style: style.copyWith(
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = strokeWidth
              ..color = strokeColor,
          ),
        ),
        // 黄色の塗り
        Text(text, style: style.copyWith(color: fillColor)),
      ],
    );
  }
}

class LanguageSelector extends StatelessWidget {
  const LanguageSelector({super.key});

  @override
  Widget build(BuildContext context) {
    final currentLocale = context.locale;

    final supportedLocales = const [
      Locale('ja'),
      Locale('en'),
      Locale('zh'),
      Locale('ko'),
    ];

    return DropdownButton<Locale>(
      value: supportedLocales.contains(currentLocale)
          ? currentLocale
          : const Locale('ja'),
      dropdownColor: AppPalette.pageBg,
      underline: Container(
        height: AppDims.border / 3,
        color: AppPalette.border,
      ),
      iconEnabledColor: AppPalette.black,

      items: supportedLocales.map((locale) {
        final label = _getLabel(locale.languageCode);

        return DropdownMenuItem(
          value: locale,
          child: Text(
            label,
            style: AppTypography.label2().copyWith(
              color: AppPalette.black,
              fontWeight: FontWeight.w600,
            ),
          ),
        );
      }).toList(),
      onChanged: (Locale? newLocale) {
        if (newLocale != null) {
          context.setLocale(newLocale);
        }
      },
    );
  }

  /// 言語コードに応じたラベル
  String _getLabel(String code) {
    switch (code) {
      case 'ja':
        return '日本語';
      case 'en':
        return 'English';
      case 'zh':
        return '中文';
      case 'ko':
        return '한국어';
      default:
        return code;
    }
  }
}

/// ===============================================================
/// ページ本体
/// ===============================================================
class PublicStorePage extends StatefulWidget {
  const PublicStorePage({super.key});

  @override
  State<PublicStorePage> createState() => PublicStorePageState();
}

class PublicStorePageState extends State<PublicStorePage> {
  String? tenantId;
  String? tenantName;
  String? employeeId;
  String? name;
  String? email;
  String? photoUrl;
  String? uid;
  String? tenantPlan;

  final _searchCtrl = TextEditingController();
  String _query = '';
  bool _showAllMembers = false;

  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() {
      setState(() => _query = _searchCtrl.text.trim().toLowerCase());
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loadFromRouteOrQuery();
  }

  // 追加：クエリ取得ヘルパー（? と # 両方対応）
  String? _getParam(String key) {
    // 1) 先に ? クエリ
    final v1 = Uri.base.queryParameters[key];
    if (v1 != null && v1.isNotEmpty) return v1;

    // 2) 次に # の中（/#/p?t=...&u=... みたいな形）
    final frag = Uri.base.fragment;
    if (frag.isNotEmpty) {
      final s = frag.startsWith('/')
          ? frag.substring(1)
          : frag; // "/p?..." → "p?..."
      final f = Uri.tryParse(s);
      final v2 = f?.queryParameters[key];
      if (v2 != null && v2.isNotEmpty) return v2;
    }
    return null;
  }

  Future<void> _loadFromRouteOrQuery() async {
    // 1) Navigator args（あれば優先）
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is Map) {
      tenantId = args['tenantId'] as String? ?? tenantId;
      employeeId = args['employeeId'] as String? ?? employeeId;
      name = args['name'] as String? ?? name;
      email = args['email'] as String? ?? email;
      photoUrl = args['photoUrl'] as String? ?? photoUrl;
      tenantName = args['tenantName'] as String? ?? tenantName;
      uid = args['uid'] as String? ?? uid;
    }

    // 2) URL（? と # の両方を見る）
    tenantId ??= _getParam('t');
    uid ??= _getParam('u');

    // 3) uid がまだ無い → tenantIndex から逆引き（公開可の前提）
    if (uid == null && tenantId != null) {
      try {
        final idx = await FirebaseFirestore.instance
            .collection('tenantIndex')
            .doc(tenantId!)
            .get();
        uid = idx.data()?['uid'] as String?;
      } catch (_) {
        /* 無視 */
      }
    }

    // 4) 店舗名の解決（両方そろってから）
    if (tenantId != null && uid != null && tenantName == null) {
      final doc = await FirebaseFirestore.instance
          .collection(uid!)
          .doc(tenantId!)
          .get();
      if (doc.exists) {
        tenantName = (doc.data()?['name'] as String?) ?? '店舗';
        final sub = doc.data()?['subscription'] as Map<String, dynamic>?;
        tenantPlan = sub?['plan'] as String?;
      }
    }

    if (mounted) setState(() {});
  }

  Future<void> openStoreTipSheet() async {
    if (tenantId == null) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppPalette.yellow,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) =>
          _StoreTipBottomSheet(tenantId: tenantId!, tenantName: tenantName),
    );
  }

  @override
  Widget build(BuildContext context) {
    // tenantId 不明 → 404 表示（現状どおり）
    if (tenantId == null) {
      return Scaffold(body: Center(child: Text(tr("status.not_found"))));
    }
    // uid がまだ解決できていない → ローディング表示にして Firestore を触らない
    if (uid == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final tenantDocStream = FirebaseFirestore.instance
        .collection(uid!)
        .doc(tenantId)
        .snapshots();

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: tenantDocStream,
      builder: (context, tSnap) {
        final tData = tSnap.data?.data();
        final subType = (tData?['subscription']?['plan'] as String?)
            ?.toUpperCase();
        final isTypeC =
            subType == 'C' || ((tenantPlan ?? '').toUpperCase() == 'C');

        final lineUrl =
            (tData?['publicLinks']?['lineOfficialUrl'] as String?) ?? '';
        final googleReviewUrl =
            (tData?['publicLinks']?['googleReviewUrl'] as String?) ?? '';

        return Scaffold(
          backgroundColor: AppPalette.pageBg,
          appBar: AppBar(
            backgroundColor: AppPalette.pageBg,
            foregroundColor: AppPalette.black,
            elevation: 0,
            automaticallyImplyLeading: false,
            scrolledUnderElevation: 0,
            // title: Text(
            //   tenantName ?? tr('store0'),
            //   style: AppTypography.body(),
            // ),
            // bottom: PreferredSize(
            //   preferredSize: const Size.fromHeight(1),
            //   child: Container(
            //     color: AppPalette.border, // 線の色
            //     height: AppDims.border,
            //   ),
            // ),
            actions: const [
              Padding(
                padding: EdgeInsets.only(right: 12),
                child: LanguageSelector(),
              ),
            ],
          ),
          body: SingleChildScrollView(
            controller: _scrollController,
            padding: const EdgeInsets.only(
              top: 12,
              bottom: 24,
              left: 12,
              right: 12,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── HERO：チップを贈ろう ─────────────────────
                Center(
                  child: RichText(
                    textAlign: TextAlign.center,
                    text: TextSpan(
                      style: AppTypography.headlineHuge(
                        color: AppPalette.black,
                      ),
                      children: [
                        WidgetSpan(
                          alignment: PlaceholderAlignment.baseline, // ← 基準線に揃える
                          baseline: TextBaseline.ideographic, // ← 日本語に適した基準線
                          child: StrokeText(
                            'チップ',
                            style: AppTypography.headlineHuge(),
                            strokeWidth: 4,
                          ),
                        ),
                        TextSpan(
                          text: 'を\n',
                          style: AppTypography.headlineLarge(),
                        ),
                        TextSpan(
                          text: '贈ろう',
                          style: AppTypography.headlineHuge(),
                        ),
                      ],
                    ),
                  ),
                ),

                SizedBox(height: 12),

                // ── メンバー ────────────────────────────────
                _Sectionbar(title: tr('section.members')),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppDims.pad,
                    0,
                    AppDims.pad,
                    0,
                  ),
                  child: TextField(
                    controller: _searchCtrl,
                    decoration: InputDecoration(
                      hintText: tr('button.search_staff'),
                      hintStyle: AppTypography.small(
                        color: AppPalette.textSecondary,
                      ),
                      prefixIcon: const Icon(
                        Icons.search,
                        color: AppPalette.textSecondary,
                      ),
                      filled: true,
                      fillColor: AppPalette.white,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppDims.radius),
                        borderSide: const BorderSide(
                          color: AppPalette.border,
                          width: AppDims.border,
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppDims.radius),
                        borderSide: const BorderSide(
                          color: AppPalette.yellow,
                          width: AppDims.border,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),

                StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance
                      .collection(uid!)
                      .doc(tenantId)
                      .collection('employees')
                      .orderBy('createdAt', descending: true)
                      .snapshots(),
                  builder: (context, snap) {
                    if (snap.hasError) {
                      return Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          tr("stripe.error", args: [snap.toString()]),
                        ),
                      );
                    }
                    if (!snap.hasData) {
                      return const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }

                    final all = snap.data!.docs.toList();
                    final filtered = all.where((doc) {
                      final d = doc.data() as Map<String, dynamic>;
                      final nm = (d['name'] ?? '').toString().toLowerCase();
                      return _query.isEmpty || nm.contains(_query);
                    }).toList();

                    if (filtered.isEmpty) {
                      return Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: Text(tr('status.no_staff'))),
                      );
                    }

                    final displayList = _showAllMembers
                        ? filtered
                        : filtered.take(6).toList();

                    return Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppDims.pad,
                        8,
                        AppDims.pad,
                        0,
                      ),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final w = constraints.maxWidth;
                          int cross = 2; // モバイル想定
                          if (w >= 1100) {
                            cross = 5;
                          } else if (w >= 900) {
                            cross = 4;
                          } else if (w >= 680) {
                            cross = 3;
                          }
                          return GridView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: cross,
                                  mainAxisSpacing: 14,
                                  crossAxisSpacing: 14,
                                  mainAxisExtent: 200,
                                ),
                            itemCount: displayList.length,
                            itemBuilder: (_, i) {
                              final doc = displayList[i];
                              final data = doc.data() as Map<String, dynamic>;
                              final id = doc.id;
                              final name = (data['name'] ?? '') as String;
                              final email = (data['email'] ?? '') as String;
                              final photoUrl =
                                  (data['photoUrl'] ?? '') as String;

                              return _RankedMemberCard(
                                rankLabel: i < 4
                                    ? tr(
                                        'staff.number',
                                        namedArgs: {'rank': '${i + 1}'},
                                      )
                                    : tr('section.members'),
                                name: name,
                                photoUrl: photoUrl,
                                onTap: () {
                                  Navigator.pushNamed(
                                    context,
                                    '/staff',
                                    arguments: {
                                      'tenantId': tenantId,
                                      'tenantName': tenantName,
                                      'employeeId': id,
                                      'name': name,
                                      'email': email,
                                      'photoUrl': photoUrl,
                                      'uid': uid,
                                    },
                                  );
                                },
                              );
                            },
                          );
                        },
                      ),
                    );
                  },
                ),

                const SizedBox(height: 8),
                Center(
                  child: TextButton(
                    onPressed: () =>
                        setState(() => _showAllMembers = !_showAllMembers),
                    child: Text(
                      _showAllMembers
                          ? tr('button.close')
                          : tr('button.see_more'),
                      style: AppTypography.label2(
                        color: AppPalette.textSecondary,
                      ),
                    ),
                  ),
                ),

                // ── お店にチップ ─────────────────────────────
                _Sectionbar(title: tr('section.store')),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppDims.pad),
                  child: SizedBox(
                    height: 100,
                    child: _YellowActionButton(
                      label: tr('button.send_tip_for_store'),
                      icon: Icons.currency_yen,
                      onPressed: openStoreTipSheet,
                    ),
                  ),
                ),
                const SizedBox(height: 10),

                // ── ご協力お願いします（Cタイプのみ表示） ───────────
                if (isTypeC) ...[
                  _Sectionbar(title: tr('section.initiate1')),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppDims.pad,
                    ),
                    child: Column(
                      children: [
                        SizedBox(
                          height: 100,
                          child: _YellowActionButton(
                            label: tr('button.LINE'),
                            onPressed: lineUrl.isEmpty
                                ? null
                                : () => launchUrlString(
                                    lineUrl,
                                    mode: LaunchMode.externalApplication,
                                  ),
                          ),
                        ),
                        const SizedBox(height: 15),
                        SizedBox(
                          height: 100,
                          child: _YellowActionButton(
                            label: tr('button.Google_review'),
                            onPressed: googleReviewUrl.isEmpty
                                ? null
                                : () => launchUrlString(
                                    googleReviewUrl,
                                    mode: LaunchMode.externalApplication,
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                // ── チップリを導入しよう（PR） ─────────────────
                _Sectionbar(title: tr('section.initiate2')),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppDims.pad),
                  child: Text('写真を挿入'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 黄色×黒の大ボタン（色は任意で上書き可）
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

    final child = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon != null) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppPalette.white,
              shape: BoxShape.circle, // ← 正円
              border: Border.all(
                color: AppPalette.black,
                width: AppDims.border2,
              ),
            ),
            child: Icon(icon, color: AppPalette.black, weight: 3200),
          ),

          const SizedBox(width: 16),
        ],
        Text(label, style: AppTypography.label2(color: AppPalette.black)),
      ],
    );

    return Material(
      color: bg, // ← 指定があればその色、なければ黄色
      borderRadius: BorderRadius.circular(AppDims.radius),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(AppDims.radius),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppDims.radius),
            border: Border.all(color: AppPalette.border, width: AppDims.border),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// 三角形の吹き出し風セクションバー
class _Sectionbar extends StatelessWidget {
  const _Sectionbar({
    this.color = AppPalette.border,
    this.thickness = AppDims.border,
    this.notchWidth = 18,
    this.notchHeight = 10,
    this.margin = const EdgeInsets.only(
      top: 12,
      left: 12,
      right: 12,
      bottom: 4,
    ),
    this.alignment = Alignment.center, // 左寄せ=Alignment.centerLeft, 右寄せ=...Right
    required this.title,
  });

  final Color color;
  final double thickness;
  final double notchWidth;
  final double notchHeight;
  final EdgeInsetsGeometry margin;
  final Alignment alignment;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: margin,
      child: Column(
        children: [
          Center(child: Text(title, style: AppTypography.label2())),
          SizedBox(height: 8),
          SizedBox(
            // ノッチ分の高さを確保（線の下に三角が付く）
            height: notchHeight + thickness,
            width: double.infinity,
            child: CustomPaint(
              painter: _SectionbarPainter(
                color: color,
                thickness: thickness,
                notchWidth: notchWidth,
                notchHeight: notchHeight,
                alignX: alignment.x, // -1.0(左) ～ 1.0(右)
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionbarPainter extends CustomPainter {
  _SectionbarPainter({
    required this.color,
    required this.thickness,
    required this.notchWidth,
    required this.notchHeight,
    required this.alignX, // -1.0(left) .. 1.0(right)
  });

  final Color color;
  final double thickness;
  final double notchWidth; // 水平幅（見た目の“くぼみ”の左右端）
  final double notchHeight; // 下方向の深さ
  final double alignX;

  @override
  void paint(Canvas canvas, Size size) {
    final y = thickness / 2; // 線の中心Y
    final r = thickness / 2; // 端の丸みと同じ半径

    // -1..1 -> [0..width]
    double cx = ((alignX + 1) / 2) * size.width;

    // ノッチが端の丸みにめり込まないようにクランプ
    final minCx = r + notchWidth / 2;
    final maxCx = size.width - r - notchWidth / 2;
    cx = cx.clamp(minCx, maxCx);

    final left = Offset(r, y);
    final right = Offset(size.width - r, y);

    final path = Path()
      ..moveTo(left.dx, left.dy)
      ..lineTo(cx - notchWidth / 2, y) // ノッチ左肩
      ..lineTo(cx, y + notchHeight) // ノッチ底
      ..lineTo(cx + notchWidth / 2, y) // ノッチ右肩
      ..lineTo(right.dx, right.dy); // 右端

    final paintStroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = thickness
      ..strokeCap = StrokeCap
          .round // 両端まる
      ..strokeJoin = StrokeJoin.round; // ノッチ肩の結合を丸く

    canvas.drawPath(path, paintStroke);
  }

  @override
  bool shouldRepaint(covariant _SectionbarPainter old) =>
      old.color != color ||
      old.thickness != thickness ||
      old.notchWidth != notchWidth ||
      old.notchHeight != notchHeight ||
      old.alignX != alignX;
}

/// ランキング風メンバーカード（黄色地＋黒枠）
class _RankedMemberCard extends StatelessWidget {
  final String rankLabel; // "第1位" or "メンバー"
  final String name;
  final String photoUrl;
  final VoidCallback? onTap;
  const _RankedMemberCard({
    required this.rankLabel,
    required this.name,
    required this.photoUrl,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hasPhoto = photoUrl.isNotEmpty;
    return Material(
      color: AppPalette.yellow,
      borderRadius: BorderRadius.circular(AppDims.radius),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppDims.radius),
            border: Border.all(color: AppPalette.black, width: AppDims.border),
          ),
          child: Column(
            children: [
              // 上部ラベル + 細線
              Text(
                rankLabel,
                style: AppTypography.body(color: AppPalette.black),
              ),
              const SizedBox(height: 4),
              Container(
                height: AppDims.border2,
                decoration: BoxDecoration(
                  color: AppPalette.black,
                  borderRadius: BorderRadius.circular(8), // ← ここで角丸指定
                ),
              ),

              const SizedBox(height: 12),

              // アバター
              Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppPalette.white,
                  border: Border.all(
                    color: AppPalette.black,
                    width: AppDims.border2,
                  ),
                  image: hasPhoto
                      ? DecorationImage(
                          image: NetworkImage(photoUrl),
                          fit: BoxFit.cover,
                        )
                      : null,
                ),
                alignment: Alignment.center,
                child: !hasPhoto
                    ? Icon(
                        Icons.person,
                        color: AppPalette.black.withOpacity(.65),
                        size: 36,
                      )
                    : null,
              ),
              const SizedBox(height: 10),

              // 名前
              Text(
                name.isEmpty ? 'スタッフ' : name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.body(color: AppPalette.black),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// ───────────────────────────────────────────────────────────────
/// 店舗チップ用 BottomSheet（既存のまま/色はデフォルト）
/// ───────────────────────────────────────────────────────────────
class _StoreTipBottomSheet extends StatefulWidget {
  final String tenantId;
  final String? tenantName;
  const _StoreTipBottomSheet({required this.tenantId, this.tenantName});

  @override
  State<_StoreTipBottomSheet> createState() => _StoreTipBottomSheetState();
}

class _StoreTipBottomSheetState extends State<_StoreTipBottomSheet> {
  int _amount = 500;
  bool _loading = false;

  static const int _maxStoreTip = 1000000;
  final _presets = const [1000, 3000, 5000, 10000];

  void _setAmount(int v) => setState(() => _amount = v.clamp(0, _maxStoreTip));
  void _appendDigit(int d) =>
      setState(() => _amount = (_amount * 10 + d).clamp(0, _maxStoreTip));
  void _appendDoubleZero() => setState(
    () => _amount = _amount == 0 ? 0 : (_amount * 100).clamp(0, _maxStoreTip),
  );
  void _backspace() => setState(() => _amount = _amount ~/ 10);
  String _fmt(int n) => n.toString();

  Future<void> _goStripe() async {
    if (_amount <= 0 || _amount > _maxStoreTip) {
      if (!mounted) return;
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
      final res = await callable.call({
        'tenantId': widget.tenantId,
        'amount': _amount,
        'memo': 'Tip to store ${widget.tenantName ?? ''}',
      });
      final data = Map<String, dynamic>.from(res.data as Map);
      final checkoutUrl = data['checkoutUrl'] as String?;
      if (checkoutUrl == null || checkoutUrl.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(tr('stripe.miss_URL'))));
        return;
      }
      if (mounted) Navigator.pop(context);
      await launchUrlString(checkoutUrl, mode: LaunchMode.externalApplication);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr("stripe.error", args: [e.toString()]))),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final maxH = MediaQuery.of(context).size.height * 0.88;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxH),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.storefront, color: Colors.black87),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.tenantName == null
                        ? tr('stripe.tip_for_store')
                        : tr(
                            'stripe.tip_for_store1',
                            namedArgs: {
                              'tenantName': widget.tenantName ?? tr('store0'),
                            },
                          ),
                    style: AppTypography.label(),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close, color: AppPalette.black),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: AppPalette.black,
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
                      _fmt(_amount),
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
                    icon: const Icon(Icons.clear, color: AppPalette.black),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _presets.map((v) {
                  final active = _amount == v;
                  return ChoiceChip(
                    side: BorderSide(
                      color: AppPalette.border,
                      width: AppDims.border,
                    ),
                    label: Text('¥${_fmt(v)}'),
                    selected: active,
                    showCheckmark: false,
                    backgroundColor: active
                        ? AppPalette.black
                        : AppPalette.white,
                    selectedColor: AppPalette.black,
                    labelStyle: TextStyle(
                      color: active ? AppPalette.white : AppPalette.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                    onSelected: (_) => _setAmount(v),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 12),
            _Keypad(
              onTapDigit: _appendDigit,
              onTapDoubleZero: _appendDoubleZero,
              onBackspace: _backspace,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Flexible(
                  flex: 1,
                  child: _YellowActionButton(
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
      child: Text(label, style: AppTypography.label()),
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
