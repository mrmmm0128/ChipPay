import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';

/// ===============================================================
/// スタイル一元管理
/// ===============================================================
class AppPalette {
  // ベース
  static const Color black = Color(0xFF000000);
  static const Color white = Color(0xFFFFFFFF);

  // ブランド黄色（画像のトーンに近い少し濃いめ）:
  // 必要ならここを差し替えるだけで全体が変わります
  static const Color yellow = Color(0xFFFCC400);

  // 背景
  static const Color pageBg = Color(0xFFF7F7F7);

  // 枠色・線
  static const Color border = black;

  // 補助
  static const Color textPrimary = Colors.black87;
  static const Color textSecondary = Colors.black54;
}

class AppDims {
  static const double border = 5; // 黒太枠
  static const double radius = 14.0;
  static const double pad = 16.0;
}

class AppTypography {
  // ここを変えるだけでフォント全体を差し替えできます
  static const String fontFamily = 'Roboto';

  static TextStyle headlineHuge({Color? color}) => TextStyle(
    fontFamily: fontFamily,
    fontSize: 32,
    fontWeight: FontWeight.w900,
    height: 1.1,
    color: color ?? AppPalette.black,
  );

  static TextStyle headlineLarge({Color? color}) => TextStyle(
    fontFamily: fontFamily,
    fontSize: 24,
    fontWeight: FontWeight.w800,
    color: color ?? AppPalette.textPrimary,
  );

  static TextStyle label({Color? color, FontWeight weight = FontWeight.w700}) =>
      TextStyle(
        fontFamily: fontFamily,
        fontSize: 14,
        fontWeight: weight,
        color: color ?? AppPalette.textPrimary,
      );

  static TextStyle body({Color? color}) => TextStyle(
    fontFamily: fontFamily,
    fontSize: 20,
    fontWeight: FontWeight.w700,
    color: color ?? AppPalette.textPrimary,
  );

  static TextStyle small({Color? color}) => TextStyle(
    fontFamily: fontFamily,
    fontSize: 12,
    color: color ?? AppPalette.textSecondary,
  );
}

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
    this.strokeWidth = 6,
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

/// セクションタイトル（下に小さなノッチ付き）
class SectionHeader extends StatelessWidget {
  final String title;
  final IconData? icon;
  const SectionHeader({super.key, required this.title, this.icon});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppDims.pad,
        20,
        AppDims.pad,
        AppDims.pad,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, color: AppPalette.textPrimary),
                const SizedBox(width: 8),
              ],
              Text(title, style: AppTypography.label(weight: FontWeight.w800)),
            ],
          ),
          const SizedBox(height: 10),
          // 直線 + ノッチ
          Stack(
            clipBehavior: Clip.none,
            children: [
              Container(height: 4, color: AppPalette.black),
              Positioned(
                left: 12,
                top: 4,
                child: Transform.rotate(
                  angle: 3.14159, // 逆三角
                  child: CustomPaint(
                    painter: _TrianglePainter(color: AppPalette.black),
                    size: const Size(16, 8),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TrianglePainter extends CustomPainter {
  final Color color;
  _TrianglePainter({required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = color;
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    canvas.drawPath(path, p);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// ===============================================================
/// ページ本体
/// ===============================================================
class PublicStorePage extends StatefulWidget {
  const PublicStorePage({super.key});

  @override
  State<PublicStorePage> createState() => _PublicStorePageState();
}

class _PublicStorePageState extends State<PublicStorePage> {
  String? tenantId;
  String? tenantName;

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

  Future<void> _loadFromRouteOrQuery() async {
    // 1) Navigator 引数
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is Map && args['tenantId'] is String) {
      tenantId = args['tenantId'] as String;
      tenantName = args['tenantName'] as String?;
    }
    // 2) URL クエリ（/p?t=...）
    tenantId ??= Uri.base.queryParameters['t'];
    // 3) ハッシュ（#/p?t=...）
    if (tenantId == null && Uri.base.fragment.isNotEmpty) {
      final frag = Uri.base.fragment.startsWith('/')
          ? Uri.base.fragment.substring(1)
          : Uri.base.fragment;
      final fUri = Uri.parse(frag);
      tenantId = fUri.queryParameters['t'];
    }

    if (tenantId != null && tenantName == null) {
      final doc = await FirebaseFirestore.instance
          .collection('tenants')
          .doc(tenantId)
          .get();
      if (doc.exists) {
        tenantName = (doc.data()!['name'] as String?) ?? '店舗';
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _openStoreTipSheet() async {
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
    if (tenantId == null) {
      return const Scaffold(
        body: Center(child: Text('店舗が見つかりません（URLをご確認ください）')),
      );
    }

    final tenantDocStream = FirebaseFirestore.instance
        .collection('tenants')
        .doc(tenantId)
        .snapshots();

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: tenantDocStream,
      builder: (context, tSnap) {
        final tData = tSnap.data?.data();
        final subType = (tData?['subscription']?['type'] as String?)
            ?.toUpperCase();
        final isTypeC = subType == 'C';

        final lineUrl =
            (tData?['publicLinks']?['lineOfficialUrl'] as String?) ?? '';
        final googleReviewUrl =
            (tData?['publicLinks']?['googleReviewUrl'] as String?) ?? '';

        return Scaffold(
          backgroundColor: AppPalette.pageBg,
          appBar: AppBar(
            backgroundColor: AppPalette.yellow,
            foregroundColor: AppPalette.black,
            elevation: 0,
            automaticallyImplyLeading: false,
            title: Text(tenantName ?? '店舗', style: AppTypography.body()),
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(1),
              child: Container(
                color: AppPalette.border, // 線の色
                height: AppDims.border,
              ),
            ),
          ),
          body: SingleChildScrollView(
            controller: _scrollController,
            padding: const EdgeInsets.only(bottom: 24),
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
                          child: StrokeText(
                            'チップ',
                            style: AppTypography.headlineHuge(),
                            strokeWidth: 8,
                          ),
                        ),
                        const TextSpan(text: 'を\n贈ろう'),
                      ],
                    ),
                  ),
                ),

                // ── メンバー ────────────────────────────────
                _Sectionbar(title: 'メンバー'),
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
                      hintText: '名前で検索する',
                      hintStyle: AppTypography.small(),
                      prefixIcon: const Icon(
                        Icons.search,
                        color: AppPalette.black,
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
                      .collection('tenants')
                      .doc(tenantId)
                      .collection('employees')
                      .orderBy('createdAt', descending: true)
                      .snapshots(),
                  builder: (context, snap) {
                    if (snap.hasError) {
                      return Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text('読み込みエラー: ${snap.error}'),
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
                      return const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: Text('該当するスタッフがいません')),
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
                                rankLabel: i < 4 ? '第${i + 1}位' : 'メンバー',
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
                      _showAllMembers ? '閉じる' : 'もっと見る',
                      style: AppTypography.label(
                        color: AppPalette.textSecondary,
                      ),
                    ),
                  ),
                ),

                // ── お店にチップ ─────────────────────────────
                _Sectionbar(title: 'お店'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppDims.pad),
                  child: SizedBox(
                    height: 80,
                    child: _YellowActionButton(
                      label: 'お店にチップを贈る',
                      icon: Icons.currency_yen,
                      onPressed: _openStoreTipSheet,
                    ),
                  ),
                ),
                const SizedBox(height: 10),

                // ── ご協力お願いします（Cタイプのみ表示） ───────────
                if (!isTypeC) ...[
                  _Sectionbar(title: 'ご協力お願いします'),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppDims.pad,
                    ),
                    child: Column(
                      children: [
                        SizedBox(
                          height: 60,
                          child: _YellowActionButton(
                            label: '公式LINE',
                            onPressed: lineUrl.isEmpty
                                ? null
                                : () => launchUrlString(
                                    lineUrl,
                                    mode: LaunchMode.externalApplication,
                                  ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          height: 60,
                          child: _YellowActionButton(
                            label: 'Googleの口コミ',
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
                _Sectionbar(title: 'チップリを導入しよう'),
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

/// 黄色×黒の大ボタン
class _YellowActionButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  const _YellowActionButton({required this.label, this.icon, this.onPressed});

  @override
  Widget build(BuildContext context) {
    final child = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon != null) ...[
          Icon(icon, color: AppPalette.black),
          const SizedBox(width: 8),
        ],
        Text(label, style: AppTypography.label(color: AppPalette.black)),
      ],
    );

    return Material(
      color: AppPalette.yellow,
      borderRadius: BorderRadius.circular(AppDims.radius),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(AppDims.radius),
        child: Container(
          padding: EdgeInsets.symmetric(vertical: 12),
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
          Center(child: Text(title, style: AppTypography.label())),
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
    required this.alignX,
  });

  final Color color;
  final double thickness;
  final double notchWidth;
  final double notchHeight;
  final double alignX;

  @override
  void paint(Canvas canvas, Size size) {
    // 水平線（上端側に描いて、下にノッチを付ける）
    final linePaint = Paint()
      ..color = color
      ..strokeWidth = thickness
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.butt;

    // 線のY座標（きれいに出るよう、stroke中心に合わせる）
    final y = thickness / 2;
    canvas.drawLine(Offset(0, y), Offset(size.width, y), linePaint);

    // ノッチ（塗りつぶし三角形）
    final cx = ((alignX + 1) / 2) * size.width; // -1..1 → 0..width
    final path = Path()
      ..moveTo(cx - notchWidth / 2, y) // 左上（線上）
      ..lineTo(cx + notchWidth / 2, y) // 右上（線上）
      ..lineTo(cx, y + notchHeight) // 下の頂点
      ..close();

    final fill = Paint()..color = color;
    canvas.drawPath(path, fill);
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
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppDims.radius),
            border: Border.all(color: AppPalette.black, width: AppDims.border),
          ),
          child: Column(
            children: [
              // 上部ラベル + 細線
              Text(
                rankLabel,
                style: AppTypography.label(color: AppPalette.black),
              ),
              const SizedBox(height: 4),
              Container(height: 2, color: AppPalette.black),
              const SizedBox(height: 12),

              // アバター
              Container(
                width: 76,
                height: 76,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppPalette.white,
                  border: Border.all(
                    color: AppPalette.black,
                    width: AppDims.border,
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
      ).showSnackBar(const SnackBar(content: Text('1〜1,000,000 円で入力してください')));
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
        ).showSnackBar(const SnackBar(content: Text('決済URLの取得に失敗しました')));
        return;
      }
      if (mounted) Navigator.pop(context);
      await launchUrlString(checkoutUrl, mode: LaunchMode.externalApplication);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('エラー: $e')));
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
                        ? '店舗にチップ'
                        : '${widget.tenantName} にチップ',
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
                SizedBox(
                  child: _YellowActionButton(
                    label: 'キャンセル',
                    onPressed: _loading ? null : () => Navigator.pop(context),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  child: _YellowActionButton(
                    label: 'チップを贈る',
                    onPressed: _loading ? null : _goStripe,
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
