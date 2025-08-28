// lib/tenant/store_detail/tabs/store_qr_tab.dart
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:url_launcher/url_launcher_string.dart';

import 'package:qr_flutter/qr_flutter.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import 'package:barcode/barcode.dart';

class StoreQrTab extends StatefulWidget {
  final String tenantId;
  final String? tenantName;
  final String posterAssetPath; // 例: 'assets/posters/store_poster.png'
  const StoreQrTab({
    super.key,
    required this.tenantId,
    this.tenantName,
    this.posterAssetPath = 'assets/posters/store_poster.png',
  });

  @override
  State<StoreQrTab> createState() => _StoreQrTabState();
}

class _PosterOption {
  final String id; // 'asset:...' or Firestore docId
  final String label; // 表示名
  final String? assetPath; // アセットの場合のみ
  final String? url; // Storage のダウンロードURL（Firestore）
  const _PosterOption.asset(this.assetPath, {this.label = 'テンプレ'})
    : id = 'asset',
      url = null;
  const _PosterOption.remote(this.id, this.url, {required this.label})
    : assetPath = null;
  bool get isAsset => assetPath != null;
}

// ▼ 用紙定義
enum _Paper { a4, a3, letter, legal }

class _PaperDef {
  final String label;
  final PdfPageFormat format; // PDF用（縦基準）
  final double widthMm; // プレビュー用（縦基準）
  final double heightMm;
  const _PaperDef(this.label, this.format, this.widthMm, this.heightMm);
}

const Map<_Paper, _PaperDef> _paperDefs = {
  _Paper.a4: _PaperDef('A4', PdfPageFormat.a4, 210, 297),
  _Paper.a3: _PaperDef('A3', PdfPageFormat.a3, 297, 420),
  _Paper.letter: _PaperDef('Letter', PdfPageFormat.letter, 216, 279),
  _Paper.legal: _PaperDef('Legal', PdfPageFormat.legal, 216, 356),
};

class _StoreQrTabState extends State<StoreQrTab> {
  final _functions = FirebaseFunctions.instanceFor(region: 'us-central1');

  String? _publicStoreUrl;
  String _selectedPosterId = 'asset'; // 既定はアセット

  // ▼ 表示/出力のカスタム設定
  bool _putWhiteBg = true; // QRの白背景
  double _qrScale = 0.35; // 画面/紙の短辺に対する占有率（20%〜60%）
  double _qrPaddingMm = 6; // QRの外側の白余白（mm）
  _Paper _paper = _Paper.a4; // 用紙
  bool _landscape = false; // 横向き切替

  @override
  void initState() {
    super.initState();
    _publicStoreUrl = _buildStoreUrl();
  }

  @override
  void didUpdateWidget(covariant StoreQrTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tenantId != widget.tenantId) {
      setState(() {
        _publicStoreUrl = _buildStoreUrl();
      });
    }
  }

  String _buildStoreUrl() {
    final origin = Uri.base.origin;
    return '$origin/#/p?t=${widget.tenantId}';
  }

  // ==== アップロード → Storage 保存 → Firestore 登録 ====
  Future<void> _addPosterFromFile() async {
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
        withData: true,
      );
      if (picked == null || picked.files.isEmpty) return;

      final f = picked.files.single;
      Uint8List? bytes = f.bytes;
      if (bytes == null && f.readStream != null) {
        final chunks = <int>[];
        await for (final c in f.readStream!) {
          chunks.addAll(c);
        }
        bytes = Uint8List.fromList(chunks);
      }
      if (bytes == null) throw '画像の読み込みに失敗しました';

      String _detectContentType(String? filename) {
        final ext = (filename ?? '').split('.').last.toLowerCase();
        switch (ext) {
          case 'jpg':
          case 'jpeg':
            return 'image/jpeg';
          case 'png':
            return 'image/png';
          case 'webp':
            return 'image/webp';
          case 'gif':
            return 'image/gif';
          default:
            return 'image/jpeg';
        }
      }

      final postersCol = FirebaseFirestore.instance
          .collection('tenants')
          .doc(widget.tenantId)
          .collection('posters');

      final docRef = postersCol.doc(); // 先にID確保
      final contentType = _detectContentType(f.name);
      final ext = contentType.split('/').last;

      final storageRef = FirebaseStorage.instance.ref().child(
        'tenants/${widget.tenantId}/posters/${docRef.id}.$ext',
      );

      await storageRef.putData(
        bytes,
        SettableMetadata(contentType: contentType),
      );
      final url = await storageRef.getDownloadURL();

      await docRef.set({
        'name': f.name,
        'url': url,
        'contentType': contentType,
        'createdAt': FieldValue.serverTimestamp(),
      });

      if (!mounted) return;
      setState(() => _selectedPosterId = docRef.id);

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('ポスターを追加しました')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('アップロード失敗: $e')));
    }
  }

  // ==== PDF 出力（アセット or ネットワーク画像）====
  Future<void> _exportPdf(List<_PosterOption> options) async {
    if (_publicStoreUrl == null) return;

    final selected = options.firstWhere(
      (o) => o.id == _selectedPosterId,
      orElse: () => options.first,
    );

    pw.ImageProvider posterProvider;
    if (selected.isAsset) {
      final b = await rootBundle.load(selected.assetPath!);
      posterProvider = pw.MemoryImage(Uint8List.view(b.buffer));
    } else {
      posterProvider = await networkImage(selected.url!);
    }

    final pdef = _paperDefs[_paper]!;
    final pageFormat = _landscape ? pdef.format.landscape : pdef.format;

    final doc = pw.Document();

    doc.addPage(
      pw.Page(
        pageFormat: pageFormat,
        build: (ctx) {
          final pageW = ctx.page.pageFormat.availableWidth;
          final pageH = ctx.page.pageFormat.availableHeight;
          final minSide = pageW < pageH ? pageW : pageH;

          final qrSidePt = minSide * _qrScale;
          final padPt = _qrPaddingMm * PdfPageFormat.mm;

          final qr = pw.BarcodeWidget(
            barcode: Barcode.qrCode(),
            data: _publicStoreUrl!,
            width: qrSidePt,
            height: qrSidePt,
            drawText: false,
            color: PdfColors.black,
          );

          final qrBox = pw.Container(
            padding: _putWhiteBg
                ? pw.EdgeInsets.all(padPt)
                : pw.EdgeInsets.zero,
            decoration: _putWhiteBg
                ? pw.BoxDecoration(
                    color: PdfColors.white,
                    borderRadius: pw.BorderRadius.circular(8),
                  )
                : const pw.BoxDecoration(),
            child: qr,
          );

          return pw.Center(
            child: pw.Stack(
              alignment: pw.Alignment.center,
              children: [
                pw.FittedBox(
                  child: pw.Image(posterProvider),
                  fit: pw.BoxFit.contain,
                ),
                qrBox, // 中央に重ねる
              ],
            ),
          );
        },
      ),
    );

    await Printing.sharePdf(
      bytes: await doc.save(),
      filename: 'store_qr_${widget.tenantId}.pdf',
    );
  }

  Future<void> _openOnboarding() async {
    // ← 旧: createAccountOnboardingLink を呼んでいたメソッドを差し替え
    try {
      // ここで最小限の事前入力（prefill）を渡します。
      // country は 'JP' を既定、businessType はお店の形態に合わせて 'individual' or 'company'
      final payload = {
        'tenantId': widget.tenantId,
        'account': {
          'country': 'JP',
          'businessType': 'individual', // or 'company'
          // 'email': FirebaseAuth.instance.currentUser?.email, // 任意
          'businessProfile': {
            // 任意: 公開ページURLや説明などがあれば入れると審査が進みやすいです
            'url': _publicStoreUrl, // 例: 店舗の公開ページ
            'product_description': 'チップ受け取り（チッププラットフォーム）',
            // 'mcc': '7299', // 必要に応じて
          },
          // 'individual': {...}, // ここに氏名/住所/生年月日/電話などを事前入力で渡せます（任意）
          // 'company': {...},    // 会社の場合の事前入力
          'tosAccepted': true, // 利用規約同意（日時/IP/UAは関数側で付与）
          // 'bankAccountToken': 'btok_xxx', // 口座をトークン化済みなら渡す（任意）
        },
      };

      final res = await _functions
          .httpsCallable('upsertConnectedAccount')
          .call(payload);

      final data = (res.data as Map?) ?? const {};
      final url = data['onboardingUrl'] as String?;
      final chargesEnabled = data['chargesEnabled'] == true;
      final payoutsEnabled = data['payoutsEnabled'] == true;

      if (url != null && url.isNotEmpty) {
        // 必須のKYCがまだ残っているときだけ、Stripeホスト画面へ
        await launchUrlString(url, mode: LaunchMode.externalApplication);
        return;
      }

      // ホスト画面に行かず完了（= 現時点の情報で要件クリア）した場合
      if (!mounted) return;
      final msg = chargesEnabled && payoutsEnabled
          ? 'Stripe接続が完了しました'
          : 'Stripe接続を更新しました（必要に応じて追加のKYCが求められることがあります）';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Stripe接続に失敗: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final black78 = Colors.black.withOpacity(0.78); // ★ 統一色
    final primary = FilledButton.styleFrom(
      backgroundColor: Colors.white,
      foregroundColor: black78, // ★
      side: const BorderSide(color: Colors.black54),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    );

    final tenantDocStream = FirebaseFirestore.instance
        .collection('tenants')
        .doc(widget.tenantId)
        .snapshots();

    final postersStream = FirebaseFirestore.instance
        .collection('tenants')
        .doc(widget.tenantId)
        .collection('posters')
        .orderBy('createdAt', descending: true)
        .snapshots();

    return StreamBuilder<DocumentSnapshot>(
      stream: tenantDocStream,
      builder: (context, tenantSnap) {
        final data = tenantSnap.data?.data() as Map<String, dynamic>?;

        final hasAccount =
            ((data?['stripeAccountId'] as String?)?.isNotEmpty ?? false);
        final connected =
            (data?['connect']?['charges_enabled'] as bool?) ?? false;

        return StreamBuilder<QuerySnapshot>(
          stream: postersStream,
          builder: (context, postersSnap) {
            final options = <_PosterOption>[
              _PosterOption.asset(widget.posterAssetPath, label: 'テンプレ'),
              ...((postersSnap.data?.docs ?? []).map((d) {
                final m = d.data() as Map<String, dynamic>;
                return _PosterOption.remote(
                  d.id,
                  (m['url'] ?? '') as String,
                  label: (m['name'] ?? 'ポスター') as String,
                );
              })),
            ];

            if (options.isNotEmpty &&
                !options.any((o) => o.id == _selectedPosterId)) {
              _selectedPosterId = options.first.id;
            }

            return LayoutBuilder(
              builder: (context, constraints) {
                final isWide = constraints.maxWidth >= 900;

                Widget paperSelector() => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    InputDecorator(
                      decoration: InputDecoration(
                        labelText: '用紙サイズ',
                        labelStyle: TextStyle(color: black78), // ★
                        hintStyle: TextStyle(color: black78), // ★
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<_Paper>(
                          value: _paper,
                          onChanged: (v) => setState(() => _paper = v!),
                          items: _paperDefs.entries
                              .map(
                                (e) => DropdownMenuItem(
                                  value: e.key,
                                  child: Text(e.value.label),
                                ),
                              )
                              .toList(),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      title: const Text(
                        '横向き（ランドスケープ）',
                        style: TextStyle(color: Colors.black87),
                      ),

                      value: _landscape,
                      dense: true,
                      onChanged: (v) => setState(() => _landscape = v),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ],
                );

                Widget pdfButton() => FilledButton.icon(
                  style: primary,
                  onPressed: (connected && _publicStoreUrl != null)
                      ? () => _exportPdf(options)
                      : null,
                  icon: const Icon(Icons.file_download),
                  label: const Text('PDFをダウンロード'),
                );

                Widget uploadButton() => OutlinedButton.icon(
                  onPressed: connected ? _addPosterFromFile : null,
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                  label: const Text('アップロード'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: black78, // ★
                    side: const BorderSide(color: Colors.black54),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                  ),
                );

                Widget posterPicker() => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'ポスターを選択',
                      style: Theme.of(
                        context,
                      ).textTheme.titleMedium?.copyWith(color: black78), // ★
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 108,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: options.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 10),
                        itemBuilder: (_, i) {
                          final opt = options[i];
                          final selected = opt.id == _selectedPosterId;
                          return GestureDetector(
                            onTap: () =>
                                setState(() => _selectedPosterId = opt.id),
                            child: Column(
                              children: [
                                Container(
                                  width: 80,
                                  height: 80,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: selected
                                          ? Colors.black
                                          : Colors.black12,
                                      width: selected ? 2 : 1,
                                    ),
                                  ),
                                  clipBehavior: Clip.antiAlias,
                                  child: opt.isAsset
                                      ? Image.asset(
                                          opt.assetPath!,
                                          fit: BoxFit.cover,
                                        )
                                      : Image.network(
                                          opt.url!,
                                          fit: BoxFit.cover,
                                        ),
                                ),
                                const SizedBox(height: 6),
                                SizedBox(
                                  width: 90,
                                  child: Text(
                                    opt.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                );

                Widget urlText() => (_publicStoreUrl == null)
                    ? const SizedBox.shrink()
                    : SelectableText(
                        _publicStoreUrl!,
                        style: TextStyle(
                          fontSize: 12,
                          color: black78, // ★
                        ),
                        textAlign: TextAlign.left,
                      );

                Widget qrControls() => DefaultTextStyle.merge(
                  style: TextStyle(color: black78), // ★
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _SliderTile(
                        label: 'QRサイズ（%）',
                        value: _qrScale,
                        min: 0.20,
                        max: 0.60,
                        displayAsPercent: true,
                        onChanged: (v) => setState(() => _qrScale = v),
                      ),
                      _SliderTile(
                        label: 'QRの余白（mm）',
                        value: _qrPaddingMm,
                        min: 0,
                        max: 20,
                        onChanged: (v) => setState(() => _qrPaddingMm = v),
                      ),
                      SwitchListTile(
                        title: const Text(
                          'QRの背景を白で敷く',
                          style: TextStyle(color: Colors.black87),
                        ),
                        value: _putWhiteBg,
                        onChanged: (v) => setState(() => _putWhiteBg = v),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ],
                  ),
                );

                Widget connectNotice() => (!connected)
                    ? Card(
                        elevation: 4,
                        shadowColor: Colors.black26,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: ListTile(
                          leading: const CircleAvatar(
                            backgroundColor: Colors.amber,
                            foregroundColor: Colors.black,
                            child: Icon(Icons.info_outline),
                          ),
                          title: const Text(
                            'Stripeオンボーディング未完了のため、QR発行はできません。',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: const Text('接続後にQRを作成できます。'),
                          trailing: FilledButton(
                            style: primary,
                            onPressed: _openOnboarding,
                            child: Text(hasAccount ? '続きから再開' : 'Stripeに接続'),
                          ),
                        ),
                      )
                    : const SizedBox.shrink();

                // 右側プレビュー
                Widget previewPane() => AspectRatio(
                  aspectRatio: () {
                    final def = _paperDefs[_paper]!;
                    final wMm = _landscape ? def.heightMm : def.widthMm;
                    final hMm = _landscape ? def.widthMm : def.heightMm;
                    return wMm / hMm;
                  }(),
                  child: LayoutBuilder(
                    builder: (context, c) {
                      final w = c.maxWidth;
                      final h = c.maxHeight;
                      final minSide = w < h ? w : h;

                      final def = _paperDefs[_paper]!;
                      final widthMm = _landscape ? def.heightMm : def.widthMm;
                      final pxPerMm = w / widthMm;
                      final padPx = _qrPaddingMm * pxPerMm;
                      final qrSidePx = minSide * _qrScale;
                      final boxSidePx =
                          qrSidePx + (_putWhiteBg ? padPx * 2 : 0);

                      final selected = options.firstWhere(
                        (o) => o.id == _selectedPosterId,
                      );
                      final posterWidget = selected.isAsset
                          ? Image.asset(selected.assetPath!, fit: BoxFit.cover)
                          : Image.network(selected.url!, fit: BoxFit.cover);

                      return Stack(
                        alignment: Alignment.center,
                        children: [
                          Positioned.fill(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: posterWidget,
                            ),
                          ),
                          if (_publicStoreUrl != null)
                            Align(
                              alignment: Alignment.center,
                              child: Transform.translate(
                                offset: const Offset(6, 0),
                                child: Container(
                                  width: boxSidePx,
                                  height: boxSidePx,
                                  decoration: BoxDecoration(
                                    color: _putWhiteBg
                                        ? Colors.white
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(8),
                                    boxShadow: _putWhiteBg
                                        ? const [
                                            BoxShadow(
                                              color: Color(0x22000000),
                                              blurRadius: 6,
                                              offset: Offset(0, 2),
                                            ),
                                          ]
                                        : null,
                                  ),
                                  alignment: Alignment.center,
                                  child: Padding(
                                    padding: EdgeInsets.all(
                                      _putWhiteBg ? padPx : 0,
                                    ),
                                    child: QrImageView(
                                      data: _publicStoreUrl!,
                                      version: QrVersions.auto,
                                      gapless: true,
                                      size: qrSidePx,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                );

                // ---- 実レイアウト ----
                if (isWide) {
                  // PC：左（操作）/ 右（プレビュー）
                  return Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 460),
                          child: SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                connectNotice(),
                                if (connected) ...[
                                  paperSelector(),
                                  const SizedBox(height: 12),
                                  Row(
                                    children: [
                                      Expanded(child: pdfButton()),
                                      const SizedBox(width: 12),
                                      Expanded(child: uploadButton()),
                                    ],
                                  ),
                                  const SizedBox(height: 16),
                                ],
                                posterPicker(),
                                const SizedBox(height: 16),
                                qrControls(),
                                const SizedBox(height: 12),
                                urlText(),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Align(
                            alignment: Alignment.topCenter,
                            child: previewPane(),
                          ),
                        ),
                      ],
                    ),
                  );
                } else {
                  // モバイル/タブ：縦積み
                  return SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        connectNotice(),
                        if (connected) ...[
                          paperSelector(), // 横向きスイッチも含む
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(child: pdfButton()),
                              const SizedBox(width: 12),
                              Expanded(child: uploadButton()),
                            ],
                          ),
                          const SizedBox(height: 16),
                        ],
                        posterPicker(),
                        const SizedBox(height: 16),
                        previewPane(),
                        const SizedBox(height: 12),
                        urlText(),
                        const SizedBox(height: 16),
                        qrControls(),
                      ],
                    ),
                  );
                }
              },
            );
          },
        );
      },
    );
  }
}

class _SliderTile extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final bool displayAsPercent;
  final ValueChanged<double> onChanged;
  const _SliderTile({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.displayAsPercent = false,
  });

  @override
  Widget build(BuildContext context) {
    final text = displayAsPercent
        ? '${(value * 100).toStringAsFixed(0)}%'
        : value.toStringAsFixed(0);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      textColor: Colors.black87,
      title: Text(label, style: TextStyle(color: Colors.black87)),
      subtitle: Slider(value: value, min: min, max: max, onChanged: onChanged),
      trailing: SizedBox(
        width: 56,
        child: Text(text, textAlign: TextAlign.end),
      ),
    );
  }
}
