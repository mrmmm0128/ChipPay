import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';

class PublicStorePage extends StatefulWidget {
  const PublicStorePage({super.key});

  @override
  State<PublicStorePage> createState() => _PublicStorePageState();
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

class _PublicStorePageState extends State<PublicStorePage> {
  String? tenantId;
  String? tenantName;

  // ▼ 名前フィルタ（スタッフ一覧セクション用）
  final _searchCtrl = TextEditingController();
  String _query = '';

  // ▼ スムーズスクロール用
  final _scrollController = ScrollController();
  final _staffSectionKey = GlobalKey();

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

  // ====== CTA 動作 ======
  Future<void> _scrollToStaffSection() async {
    final ctx = _staffSectionKey.currentContext;
    if (ctx != null) {
      await Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeInOut,
        alignment: 0.05,
      );
    }
  }

  /// 店舗チップの BottomSheet を開く
  Future<void> openStoreTip() async {
    if (tenantId == null) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.white,
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

    // テナントのサマリ（Cタイプ判定や外部リンク取得用）
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
            (tData?['publicLinks']?['lineOfficialUrl'] as String?) ??
            'https://line.me/R/ti/p/@your_store'; // 仮
        final googleReviewUrl =
            (tData?['publicLinks']?['googleReviewUrl'] as String?) ??
            'https://g.page/r/your-place-id/review'; // 仮

        return Scaffold(
          backgroundColor: const Color(0xFFF7F7F7),
          appBar: AppBar(
            backgroundColor: Colors.white,
            foregroundColor: Colors.black,
            elevation: 0,
            automaticallyImplyLeading: false,
            title: Text(
              tenantName ?? '店舗',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          body: SingleChildScrollView(
            controller: _scrollController,
            padding: const EdgeInsets.only(bottom: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('チップを送りましょう'),
                // ===== Cタイプ限定：外部リンク群 =====
                if (isTypeC)
                  _ExternalLinksRow(
                    onTapLine: () => launchUrlString(
                      lineUrl,
                      mode: LaunchMode.externalApplication,
                    ),
                    onTapGoogle: () => launchUrlString(
                      googleReviewUrl,
                      mode: LaunchMode.externalApplication,
                    ),
                  ),

                const SizedBox(height: 16),

                // ===== スタッフ一覧（アンカー） =====
                Padding(
                  key: _staffSectionKey,
                  padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
                  child: Row(
                    children: const [
                      Icon(Icons.list_alt, color: Colors.black87),
                      SizedBox(width: 8),
                      Text(
                        'スタッフ一覧',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 18,
                          color: Colors.black87,
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: TextField(
                    controller: _searchCtrl,
                    decoration: InputDecoration(
                      hintText: '名前で検索',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                _searchCtrl.clear();
                                FocusScope.of(context).unfocus();
                              },
                            ),
                      filled: true,
                      fillColor: Colors.white,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Colors.black12),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Colors.black12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),

                // グリッド（SingleChildScrollView 内に収めるため shrinkWrap）
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

                    final all = snap.data!.docs;
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

                    return LayoutBuilder(
                      builder: (context, constraints) {
                        final w = constraints.maxWidth;
                        int cross = 2;
                        if (w >= 1100) {
                          cross = 5;
                        } else if (w >= 900) {
                          cross = 4;
                        } else if (w >= 680) {
                          cross = 3;
                        }
                        return GridView.builder(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: cross,
                                mainAxisSpacing: 16,
                                crossAxisSpacing: 16,
                                mainAxisExtent:
                                    200, // ★ 高さを固定（必要に応じて調整 200〜240 など）
                              ),
                          itemCount: filtered.length,
                          itemBuilder: (_, i) {
                            final doc = filtered[i];
                            final data = doc.data() as Map<String, dynamic>;
                            final id = doc.id;
                            final name = (data['name'] ?? '') as String;
                            final email = (data['email'] ?? '') as String;
                            final photoUrl = (data['photoUrl'] ?? '') as String;

                            return _EmployeeCard(
                              rank: i + 1,
                              name: name,
                              email: email,
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
                    );
                  },
                ),
                // ===== Googleレビューへの誘導 =====
                _SectionTitle(
                  icon: Icons.reviews_outlined,
                  title: 'Googleレビュー',
                ),

                //　リンクを貼る
              ],
            ),
          ),
        );
      },
    );
  }
}

// ==================== UI パーツ ====================

class _HeroSection extends StatelessWidget {
  final String title;
  final String headline;
  final String subline;
  final VoidCallback onTapPrimary; // スタッフ一覧へ
  final VoidCallback onTapSecondary; // 店舗へチップ

  const _HeroSection({
    required this.title,
    required this.headline,
    required this.subline,
    required this.onTapPrimary,
    required this.onTapSecondary,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 店名（小さめ）
          Text(
            title,
            style: const TextStyle(
              color: Colors.black54,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 8),
          // キャッチ
          Text(
            headline,
            style: const TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w800,
              height: 1.25,
              color: Colors.black87,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            subline,
            style: const TextStyle(fontSize: 15, color: Colors.black87),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.icon(
                onPressed: onTapPrimary,
                icon: const Icon(Icons.people_alt),
                label: const Text('スタッフ一覧へ'),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.black,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              OutlinedButton.icon(
                onPressed: onTapSecondary,
                icon: const Icon(Icons.volunteer_activism),
                label: const Text('店舗にチップを送る'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.black87,
                  side: const BorderSide(color: Colors.black87),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
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

class _ExternalLinksRow extends StatelessWidget {
  final VoidCallback onTapLine;
  final VoidCallback onTapGoogle;
  const _ExternalLinksRow({required this.onTapLine, required this.onTapGoogle});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: onTapLine,
              icon: const Icon(Icons.chat_bubble_outline),
              label: const Text('LINE公式アカウント'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.black87,
                side: const BorderSide(color: Colors.black26),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: onTapGoogle,
              icon: const Icon(Icons.reviews_outlined),
              label: const Text('Google レビュー'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.black87,
                side: const BorderSide(color: Colors.black26),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? actionText;
  final VoidCallback? onAction;

  const _SectionTitle({
    required this.icon,
    required this.title,
    this.actionText,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
      child: Row(
        children: [
          Icon(icon, color: Colors.black87),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 18,
                color: Colors.black87,
              ),
            ),
          ),
          if (actionText != null)
            TextButton(
              onPressed: onAction,
              child: Text(
                actionText!,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  color: Colors.black54,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// スクロールのオーバーグロー（青い光）を消す・マウス/トラックパッドでもドラッグ可
class _NoGlowScrollBehavior extends MaterialScrollBehavior {
  const _NoGlowScrollBehavior();
  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}

class _StaffChip extends StatelessWidget {
  final String name;
  final String email;
  final String photoUrl;
  final VoidCallback? onTap;
  const _StaffChip({
    required this.name,
    required this.email,
    required this.photoUrl,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      elevation: 3,
      shadowColor: Colors.black12,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 220,
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              CircleAvatar(
                radius: 28,
                backgroundImage: (photoUrl.isNotEmpty)
                    ? NetworkImage(photoUrl)
                    : null,
                child: (photoUrl.isEmpty) ? const Icon(Icons.person) : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    if (email.isNotEmpty)
                      Text(
                        email,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: Colors.black54),
                      ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Colors.black45),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmployeeCard extends StatelessWidget {
  final int rank;
  final String name;
  final String email;
  final String photoUrl;
  final VoidCallback? onTap;

  const _EmployeeCard({
    required this.rank,
    required this.name,
    required this.email,
    required this.photoUrl,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.black12, width: 1),
          ),
          padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
          child: Column(
            children: [
              // アバター + ランクバッジ（モノトーン）
              Stack(
                clipBehavior: Clip.none,
                children: [
                  _Avatar(photoUrl: photoUrl),
                  Positioned(top: -6, left: -6, child: _RankBadge(rank: rank)),
                ],
              ),
              const SizedBox(height: 12),

              // 名前（黒・太字）
              Text(
                name.isEmpty ? 'スタッフ' : name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.black87,
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),

              // メール（補助・黒54%）
              if (email.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  email,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: Colors.black54),
                ),
              ],

              // 下部の区切り + 右下シェブロン（控えめ）
              const Divider(height: 16, thickness: 1, color: Colors.black12),
              Align(
                alignment: Alignment.bottomRight,
                child: Icon(
                  Icons.chevron_right,
                  size: 20,
                  color: Colors.black.withOpacity(0.45),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final String photoUrl;
  const _Avatar({required this.photoUrl});

  @override
  Widget build(BuildContext context) {
    const double size = 88;
    final hasPhoto = photoUrl.isNotEmpty;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: Colors.black12, width: 1),
        color: Colors.white,
        image: hasPhoto
            ? DecorationImage(image: NetworkImage(photoUrl), fit: BoxFit.cover)
            : null,
      ),
      alignment: Alignment.center,
      child: !hasPhoto
          ? const Icon(Icons.person, size: 40, color: Colors.black45)
          : null,
    );
  }
}

class _RankBadge extends StatelessWidget {
  final int rank;
  const _RankBadge({required this.rank});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        color: Colors.black,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: const [
          BoxShadow(
            blurRadius: 4,
            color: Color(0x29000000),
            offset: Offset(0, 2),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        '$rank',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

/// ───────────────────────────────────────────────────────────────
/// BottomSheet 本体（プリセット＋キーパッド＋Stripe へ進む）
/// ───────────────────────────────────────────────────────────────
class _StoreTipBottomSheet extends StatefulWidget {
  final String tenantId;
  final String? tenantName;
  const _StoreTipBottomSheet({required this.tenantId, this.tenantName});

  @override
  State<_StoreTipBottomSheet> createState() => _StoreTipBottomSheetState();
}

class _StoreTipBottomSheetState extends State<_StoreTipBottomSheet> {
  int _amount = 500; // デフォルト
  bool _loading = false;

  static const int _maxStoreTip = 1000000; // バックエンドと揃える（最大100万円）

  final _presets = const [100, 300, 500, 1000, 3000, 5000, 10000];

  void _setAmount(int v) {
    final next = v.clamp(0, _maxStoreTip);
    setState(() => _amount = next);
  }

  void _appendDigit(int d) {
    final next = (_amount * 10 + d).clamp(0, _maxStoreTip);
    setState(() => _amount = next);
  }

  void _appendDoubleZero() {
    if (_amount == 0) return;
    final next = (_amount * 100).clamp(0, _maxStoreTip);
    setState(() => _amount = next);
  }

  void _backspace() {
    setState(() => _amount = _amount ~/ 10);
  }

  String _fmt(int n) => n.toString(); // 必要なら桁区切りへ変更OK

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
      // 先にシートを閉じてから外部遷移
      if (mounted) Navigator.of(context).pop();
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
            // タイトル
            Row(
              children: [
                const Icon(Icons.storefront, color: Colors.black87),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.tenantName == null
                        ? '店舗にチップ'
                        : '${widget.tenantName} にチップ',
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
                border: Border.all(color: Colors.black12),
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
                  TextButton.icon(
                    onPressed: () => _setAmount(0),
                    icon: const Icon(Icons.clear),
                    label: const Text('クリア'),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),

            // プリセット
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _presets.map((v) {
                  final active = _amount == v;
                  return ChoiceChip(
                    label: Text('¥${_fmt(v)}'),
                    selected: active,
                    showCheckmark: false,
                    backgroundColor: active ? Colors.black : Colors.grey[100],
                    selectedColor: Colors.black,
                    labelStyle: TextStyle(
                      color: active ? Colors.white : Colors.black87,
                      fontWeight: FontWeight.w600,
                    ),
                    onSelected: (_) => _setAmount(v),
                  );
                }).toList(),
              ),
            ),

            const SizedBox(height: 12),

            // キーパッド
            _Keypad(
              onTapDigit: _appendDigit,
              onTapDoubleZero: _appendDoubleZero,
              onBackspace: _backspace,
            ),

            const SizedBox(height: 12),

            // フッター：キャンセル / Stripeへ
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _loading ? null : () => Navigator.pop(context),
                    child: const Text('キャンセル'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _loading ? null : _goStripe,
                    icon: _loading
                        ? const SizedBox(
                            height: 16,
                            width: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.open_in_new),
                    label: const Text('Stripeへ進む'),
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

/// 数字キーパッド（1〜9 / 00 / 0 / ←）
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
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(vertical: 14),
      ),
      onPressed: onPressed,
      child: Text(label, style: const TextStyle(fontSize: 18)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, c) {
        // 3列グリッドっぽく並べる
        return Column(
          children: [
            Row(
              children: [
                Expanded(child: _btn(ctx, '1', () => onTapDigit(1))),
                const SizedBox(width: 8),
                Expanded(child: _btn(ctx, '2', () => onTapDigit(2))),
                const SizedBox(width: 8),
                Expanded(child: _btn(ctx, '3', () => onTapDigit(3))),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: _btn(ctx, '4', () => onTapDigit(4))),
                const SizedBox(width: 8),
                Expanded(child: _btn(ctx, '5', () => onTapDigit(5))),
                const SizedBox(width: 8),
                Expanded(child: _btn(ctx, '6', () => onTapDigit(6))),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: _btn(ctx, '7', () => onTapDigit(7))),
                const SizedBox(width: 8),
                Expanded(child: _btn(ctx, '8', () => onTapDigit(8))),
                const SizedBox(width: 8),
                Expanded(child: _btn(ctx, '9', () => onTapDigit(9))),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: _btn(ctx, '00', onTapDoubleZero)),
                const SizedBox(width: 8),
                Expanded(child: _btn(ctx, '0', () => onTapDigit(0))),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.black87,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: onBackspace,
                    child: const Icon(Icons.backspace_outlined),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}
