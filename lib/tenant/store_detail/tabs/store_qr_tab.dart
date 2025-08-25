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
  final PdfPageFormat format; // PDF用
  final double widthMm; // プレビュー用
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

  // ▼ 追加: 表示/出力のカスタム設定
  bool _putWhiteBg = true; // QRの白背景
  double _qrScale = 0.35; // 画面/紙の短辺に対する占有率（20%〜60%）
  double _qrPaddingMm = 6; // QRの外側の白余白（mm）
  _Paper _paper = _Paper.a4; // 選択用紙

  @override
  void initState() {
    super.initState();
    // 画面表示時にデフォルトでQRを出す
    _publicStoreUrl = _buildStoreUrl();
  }

  @override
  void didUpdateWidget(covariant StoreQrTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tenantId != widget.tenantId) {
      setState(() {
        _publicStoreUrl = _buildStoreUrl(); // ← 選択中の店舗で更新
        // （必要なら）ポスター選択を初期に戻したい場合は次行のコメントを外す
        // _selectedPosterId = 'asset';
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
    final doc = pw.Document();

    doc.addPage(
      pw.Page(
        pageFormat: pdef.format, // ← 選択用紙を使用
        build: (ctx) {
          final pageW = ctx.page.pageFormat.availableWidth;
          final pageH = ctx.page.pageFormat.availableHeight;
          final minSide = pageW < pageH ? pageW : pageH;

          // サイズ・余白（pt単位）
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

    // 印刷ダイアログを出さずに直接ダウンロード/共有
    await Printing.sharePdf(
      bytes: await doc.save(),
      filename: 'store_qr_${widget.tenantId}.pdf',
    );
  }

  Future<void> _openOnboarding() async {
    try {
      final res = await _functions
          .httpsCallable('createAccountOnboardingLink')
          .call({'tenantId': widget.tenantId});
      final url = (res.data as Map)['url'] as String;
      await launchUrlString(url, mode: LaunchMode.externalApplication);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('オンボーディングリンク取得に失敗: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final primary = FilledButton.styleFrom(
      backgroundColor: Colors.white, // ★ 背景を白に
      foregroundColor: Colors.black87, // ★ テキスト/アイコンを黒87に
      side: const BorderSide(color: Colors.black54), // 枠線（視認性のため）
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

            if (!options.any((o) => o.id == _selectedPosterId)) {
              _selectedPosterId = options.first.id;
            }

            return Theme(
              data: Theme.of(context).copyWith(
                textTheme: Theme.of(context).textTheme.apply(
                  bodyColor: Colors.black87, // ★ テキストテーマの既定色
                  displayColor: Colors.black87,
                ),
              ),
              child: DefaultTextStyle.merge(
                style: const TextStyle(color: Colors.black87), // ★ 明示的な既定色
                child: ListTileTheme(
                  data: const ListTileThemeData(
                    textColor: Colors.black87, // ★ ListTile内の文字色
                    iconColor: Colors.black87,
                  ),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (!connected)
                          Card(
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
                              title: Text(
                                hasAccount
                                    ? 'Stripeオンボーディング未完了のため、QR発行はできません。'
                                    : 'Stripe未接続のため、QR発行はできません。',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              subtitle: const Text('接続後にQRを作成できます。'),
                              trailing: FilledButton(
                                style: primary,
                                onPressed: _openOnboarding,
                                child: Text(
                                  hasAccount ? '続きから再開' : 'Stripeに接続',
                                ),
                              ),
                            ),
                          ),

                        // アクション行
                        // ▼ アクション行（置き換え）
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final isWide =
                                constraints.maxWidth >= 720; // 端末幅が広ければ横並び

                            // 用紙選択（中身そのまま流用）
                            Widget paperSelector = InputDecorator(
                              decoration: InputDecoration(
                                labelText: '用紙サイズ',
                                labelStyle: const TextStyle(
                                  color: Colors.black87,
                                ),
                                hintStyle: const TextStyle(
                                  color: Colors.black87,
                                ),
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
                            );

                            // PDFボタン
                            final pdfButton = FilledButton.icon(
                              style: primary,
                              onPressed: (connected && _publicStoreUrl != null)
                                  ? () => _exportPdf(options)
                                  : null,
                              icon: const Icon(Icons.file_download),
                              label: const Text('PDFをダウンロード'),
                            );

                            // ポスターアップロード
                            final uploadButton = OutlinedButton.icon(
                              onPressed: connected ? _addPosterFromFile : null,
                              icon: const Icon(
                                Icons.add_photo_alternate_outlined,
                              ),
                              label: const Text('ポスターをアップロード'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.black87,
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

                            if (isWide) {
                              // 横一列（用紙選択を少し広めに）
                              return Row(
                                children: [
                                  Expanded(flex: 1, child: paperSelector),
                                  const SizedBox(width: 12),
                                  Expanded(flex: 1, child: pdfButton),
                                  const SizedBox(width: 12),
                                  Expanded(flex: 1, child: uploadButton),
                                ],
                              );
                            } else {
                              // 狭い幅では縦積み→ボタン2つは横並び
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  paperSelector,
                                  const SizedBox(height: 12),
                                  Row(
                                    children: [
                                      Expanded(child: pdfButton),
                                      const SizedBox(width: 12),
                                      Expanded(child: uploadButton),
                                    ],
                                  ),
                                ],
                              );
                            }
                          },
                        ),

                        const SizedBox(height: 16),
                        Text(
                          'ポスターを選択',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                color: Colors.black87, // ★ 追加
                              ),
                        ),
                        const SizedBox(height: 8),

                        // サムネ（横スクロール）
                        SizedBox(
                          height: 108,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: options.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(width: 10),
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

                        const SizedBox(height: 16),

                        // ▼ プレビュー（選択した用紙のアスペクト比）
                        AspectRatio(
                          aspectRatio: () {
                            final def = _paperDefs[_paper]!;
                            return def.widthMm / def.heightMm;
                          }(),
                          child: LayoutBuilder(
                            builder: (context, c) {
                              final w = c.maxWidth;
                              final h = c.maxHeight;
                              final minSide = w < h ? w : h;

                              final def = _paperDefs[_paper]!;
                              // mm → px 変換（幅=用紙幅mmとして換算）
                              final pxPerMm = w / def.widthMm;
                              final padPx = _qrPaddingMm * pxPerMm;

                              final qrSidePx = minSide * _qrScale;
                              final boxSidePx =
                                  qrSidePx + (_putWhiteBg ? padPx * 2 : 0);

                              final selected = options.firstWhere(
                                (o) => o.id == _selectedPosterId,
                              );
                              final posterWidget = selected.isAsset
                                  ? Image.asset(
                                      selected.assetPath!,
                                      fit: BoxFit.cover,
                                    )
                                  : Image.network(
                                      selected.url!,
                                      fit: BoxFit.cover,
                                    );

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
                                    Container(
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
                                  if (!connected)
                                    Container(
                                      color: Colors.white.withOpacity(0.6),
                                      alignment: Alignment.center,
                                      child: const Text(
                                        'Stripe接続が完了するとQRを表示できます',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                ],
                              );
                            },
                          ),
                        ),

                        const SizedBox(height: 12),
                        if (_publicStoreUrl != null)
                          SelectableText(
                            _publicStoreUrl!,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.black87,
                            ),
                            textAlign: TextAlign.center,
                          ),

                        const SizedBox(height: 16),

                        // ▼ QR見た目コントロール
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
                          title: const Text('QRの背景を白で敷く'),
                          value: _putWhiteBg,
                          onChanged: (v) => setState(() => _putWhiteBg = v),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
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
      title: Text(label),
      subtitle: Slider(value: value, min: min, max: max, onChanged: onChanged),
      trailing: SizedBox(
        width: 56,
        child: Text(text, textAlign: TextAlign.end),
      ),
    );
  }
}
