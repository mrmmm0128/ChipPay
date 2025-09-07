// lib/tenant/store_detail/tabs/store_qr_tab.dart
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'package:qr_flutter/qr_flutter.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import 'package:barcode/barcode.dart';
import 'package:yourpay/tenant/newTenant/onboardingSheet.dart';

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
  final String id; // 'asset' or Firestore docId
  final String label;
  final String? assetPath;
  final String? url;
  const _PosterOption.asset(this.assetPath, {this.label = 'テンプレ'})
    : id = 'asset',
      url = null;
  const _PosterOption.remote(this.id, this.url, {required this.label})
    : assetPath = null;
  bool get isAsset => assetPath != null;
}

// ▼ 用紙定義（A0〜A4 / B0〜B5）
enum _Paper { a0, a1, a2, a3, a4, b0, b1, b2, b3, b4, b5 }

class _PaperDef {
  final String label;
  final PdfPageFormat format; // PDF用（縦基準）
  final double widthMm; // プレビュー用（縦基準）
  final double heightMm;
  const _PaperDef(this.label, this.format, this.widthMm, this.heightMm);
}

// ISO 216 mm
const Map<_Paper, _PaperDef> _paperDefs = {
  _Paper.a0: _PaperDef(
    'A0',
    PdfPageFormat(841 * PdfPageFormat.mm, 1189 * PdfPageFormat.mm),
    841,
    1189,
  ),
  _Paper.a1: _PaperDef(
    'A1',
    PdfPageFormat(594 * PdfPageFormat.mm, 841 * PdfPageFormat.mm),
    594,
    841,
  ),
  _Paper.a2: _PaperDef(
    'A2',
    PdfPageFormat(420 * PdfPageFormat.mm, 594 * PdfPageFormat.mm),
    420,
    594,
  ),
  _Paper.a3: _PaperDef(
    'A3',
    PdfPageFormat(297 * PdfPageFormat.mm, 420 * PdfPageFormat.mm),
    297,
    420,
  ),
  _Paper.a4: _PaperDef(
    'A4',
    PdfPageFormat(210 * PdfPageFormat.mm, 297 * PdfPageFormat.mm),
    210,
    297,
  ),
  _Paper.b0: _PaperDef(
    'B0',
    PdfPageFormat(1000 * PdfPageFormat.mm, 1414 * PdfPageFormat.mm),
    1000,
    1414,
  ),
  _Paper.b1: _PaperDef(
    'B1',
    PdfPageFormat(707 * PdfPageFormat.mm, 1000 * PdfPageFormat.mm),
    707,
    1000,
  ),
  _Paper.b2: _PaperDef(
    'B2',
    PdfPageFormat(500 * PdfPageFormat.mm, 707 * PdfPageFormat.mm),
    500,
    707,
  ),
  _Paper.b3: _PaperDef(
    'B3',
    PdfPageFormat(353 * PdfPageFormat.mm, 500 * PdfPageFormat.mm),
    353,
    500,
  ),
  _Paper.b4: _PaperDef(
    'B4',
    PdfPageFormat(250 * PdfPageFormat.mm, 353 * PdfPageFormat.mm),
    250,
    353,
  ),
  _Paper.b5: _PaperDef(
    'B5',
    PdfPageFormat(176 * PdfPageFormat.mm, 250 * PdfPageFormat.mm),
    176,
    250,
  ),
};

class _StoreQrTabState extends State<StoreQrTab> {
  final _functions = FirebaseFunctions.instanceFor(region: 'us-central1');

  final uid = FirebaseAuth.instance.currentUser?.uid;

  // ------- 状態 -------
  String? _publicStoreUrl;
  String _selectedPosterId = 'asset';

  // 表示/出力カスタム
  bool _putWhiteBg = true;
  double _qrScale = 0.35; // 20〜60%
  double _qrPaddingMm = 6;
  bool _landscape = false;

  // 用紙：UI表示は setState、プレビューは _paperVN で用紙変更時のみ再描画
  _Paper _paper = _Paper.a4;
  final ValueNotifier<_Paper> _paperVN = ValueNotifier<_Paper>(_Paper.a4);

  Offset _qrPos = const Offset(0.5, 0.5);

  // Firestore
  late final Stream<QuerySnapshot<Map<String, dynamic>>> _postersStream;
  bool? _connected; // ← 一度だけ取得して保持

  @override
  void initState() {
    super.initState();
    _publicStoreUrl = _buildStoreUrl();
    _postersStream = FirebaseFirestore.instance
        .collection(uid!)
        .doc(widget.tenantId)
        .collection('posters')
        .orderBy('createdAt', descending: true)
        .snapshots();
    _loadConnectedOnce(); // ← 1回だけ読む
  }

  @override
  void didUpdateWidget(covariant StoreQrTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tenantId != widget.tenantId) {
      // テナント変更時だけ必要なものを更新
      _publicStoreUrl = _buildStoreUrl();
      _qrPos = const Offset(0.5, 0.5);
      _loadConnectedOnce();
    }
  }

  Future<void> _loadConnectedOnce() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection(uid!)
          .doc(widget.tenantId)
          .get();
      final c = (doc.data()?['connect']?['charges_enabled'] as bool?) ?? false;
      if (mounted) setState(() => _connected = c);
    } catch (_) {
      if (mounted) setState(() => _connected = false);
    }
  }

  String _buildStoreUrl() {
    final origin = Uri.base.origin;
    return '$origin/#/p?t=${widget.tenantId}&u=$uid';
    // 必要ならここでサイズやパラメータを追加
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
          .collection(uid!)
          .doc(widget.tenantId)
          .collection('posters');

      final docRef = postersCol.doc();
      final contentType = _detectContentType(f.name);
      final ext = contentType.split('/').last;

      final storageRef = FirebaseStorage.instance.ref().child(
        '$uid/${widget.tenantId}/posters/${docRef.id}.$ext',
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

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'ポスターを追加しました',
            style: TextStyle(fontFamily: 'LINEseed'),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'アップロード失敗: $e',
            style: const TextStyle(fontFamily: 'LINEseed'),
          ),
        ),
      );
    }
  }

  // ==== PDF 出力 ====
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

    final pdef = _paperDefs[_paperVN.value]!;
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
          final boxSidePt = qrSidePt + (_putWhiteBg ? padPt * 2 : 0);

          double leftPt = _qrPos.dx * pageW - boxSidePt / 2;
          double topPt = _qrPos.dy * pageH - boxSidePt / 2;
          leftPt = leftPt.clamp(0, pageW - boxSidePt);
          topPt = topPt.clamp(0, pageH - boxSidePt);

          final poster = pw.Positioned.fill(
            child: pw.FittedBox(
              child: pw.Image(posterProvider),
              fit: pw.BoxFit.cover,
            ),
          );

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

          return pw.Stack(
            children: [
              poster,
              pw.Positioned(left: leftPt, top: topPt, child: qrBox),
            ],
          );
        },
      ),
    );

    await Printing.sharePdf(
      bytes: await doc.save(),
      filename: 'store_qr_${widget.tenantId}.pdf',
    );
  }

  // ---------- オンボーディング ----------
  Future<void> startOnboarding(String tenantId, String tenantName) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      useRootNavigator: true,
      barrierColor: Colors.black38,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetCtx) {
        return Theme(
          data: bwTheme(context),
          child: OnboardingSheet(
            tenantId: tenantId,
            tenantName: tenantName,
            functions: _functions,
          ),
        );
      },
    );
  }

  ThemeData bwTheme(BuildContext context) {
    final base = Theme.of(context);
    final cs = base.colorScheme;
    OutlineInputBorder _border(Color c) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: c),
    );
    return base.copyWith(
      colorScheme: cs.copyWith(
        primary: Colors.black,
        secondary: Colors.black,
        surface: Colors.white,
        onSurface: Colors.black87,
        onPrimary: Colors.white,
        onSecondary: Colors.white,
        background: Colors.white,
      ),
      dialogBackgroundColor: Colors.white,
      scaffoldBackgroundColor: Colors.white,
      canvasColor: Colors.white,
      textTheme: base.textTheme.apply(
        bodyColor: Colors.black87,
        displayColor: Colors.black87,
      ),
      inputDecorationTheme: InputDecorationTheme(
        labelStyle: const TextStyle(color: Colors.black87),
        hintStyle: const TextStyle(color: Colors.black54),
        filled: true,
        fillColor: Colors.white,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        border: _border(Colors.black12),
        enabledBorder: _border(Colors.black12),
        focusedBorder: _border(Colors.black),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.black87,
          side: const BorderSide(color: Colors.black45),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: Colors.black87),
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: Colors.white,
        selectedColor: Colors.black12,
        labelStyle: const TextStyle(color: Colors.black87),
        side: const BorderSide(color: Colors.black26),
        showCheckmark: false,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: Colors.black,
      ),
      dividerColor: Colors.black12,
    );
  }

  @override
  void dispose() {
    _paperVN.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final black78 = Colors.black.withOpacity(0.78);
    final primary = FilledButton.styleFrom(
      backgroundColor: Colors.white,
      foregroundColor: black78,
      side: const BorderSide(color: Colors.black54),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    );

    // connected が未取得の間は軽く待機表示
    if (_connected == null) {
      return const Center(child: CircularProgressIndicator());
    }

    // ---------------- UI ----------------
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _postersStream, // ← ポスターのみストリーム
      builder: (context, postersSnap) {
        final options = <_PosterOption>[
          _PosterOption.asset(widget.posterAssetPath, label: 'テンプレ'),
          ...((postersSnap.data?.docs ?? []).map((d) {
            final m = d.data();
            return _PosterOption.remote(
              d.id,
              (m['url'] ?? '') as String,
              label: (m['name'] ?? 'ポスター') as String,
            );
          })),
        ];

        final currentPosterId = options.any((o) => o.id == _selectedPosterId)
            ? _selectedPosterId
            : (options.isNotEmpty ? options.first.id : null);

        Widget paperSelector() => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InputDecorator(
              decoration: InputDecoration(
                labelText: '用紙サイズ',
                labelStyle: TextStyle(color: black78),
                hintStyle: TextStyle(color: black78),
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
                  key: const ValueKey('paper-dd'),
                  value: _paper,
                  isDense: true,
                  onChanged: (v) {
                    if (v == null) return;
                    // 表示用の値と、プレビュー用の Notifier を更新
                    setState(() => _paper = v);
                    _paperVN.value = v; // ← これでプレビューは用紙変更時だけ再描画
                  },
                  items: _paperDefs.entries
                      .map(
                        (e) => DropdownMenuItem(
                          value: e.key,
                          child: Text(
                            e.value.label,
                            style: const TextStyle(fontFamily: 'LINEseed'),
                          ),
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
                style: TextStyle(color: Colors.black87, fontFamily: 'LINEseed'),
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
          onPressed: (_connected! && _publicStoreUrl != null)
              ? () => _exportPdf(options)
              : null,
          icon: const Icon(Icons.file_download),
          label: const Text(
            'PDFをダウンロード',
            style: TextStyle(fontFamily: 'LINEseed'),
          ),
        );

        Widget uploadButton() => OutlinedButton.icon(
          onPressed: _connected! ? _addPosterFromFile : null,
          icon: const Icon(Icons.add_photo_alternate_outlined),
          label: const Text('アップロード', style: TextStyle(fontFamily: 'LINEseed')),
          style: OutlinedButton.styleFrom(
            foregroundColor: black78,
            side: const BorderSide(color: Colors.black54),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          ),
        );

        Widget posterPicker() => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'ポスターを選択',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: black78,
                fontFamily: "LINEseed",
              ),
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
                  final selected =
                      (currentPosterId != null && opt.id == currentPosterId);
                  return GestureDetector(
                    onTap: () => setState(() => _selectedPosterId = opt.id),
                    child: Column(
                      children: [
                        Container(
                          width: 80,
                          height: 80,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: selected ? Colors.black : Colors.black12,
                              width: selected ? 2 : 1,
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: opt.isAsset
                              ? Image.asset(opt.assetPath!, fit: BoxFit.cover)
                              : Image.network(opt.url!, fit: BoxFit.cover),
                        ),
                        const SizedBox(height: 6),
                        SizedBox(
                          width: 90,
                          child: Text(
                            opt.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 12,
                              fontFamily: 'LINEseed',
                            ),
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
                  color: black78,
                  fontFamily: 'LINEseed',
                ),
                textAlign: TextAlign.left,
              );

        Widget qrControls() => DefaultTextStyle.merge(
          style: TextStyle(color: black78),
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
                  style: TextStyle(
                    color: Colors.black87,
                    fontFamily: 'LINEseed',
                  ),
                ),
                value: _putWhiteBg,
                onChanged: (v) => setState(() => _putWhiteBg = v),
                contentPadding: EdgeInsets.zero,
              ),
              const SizedBox(height: 6),
              const Text(
                'ヒント：プレビュー内のQRをドラッグで移動／ダブルタップで中央に戻せます。',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.black54,
                  fontFamily: 'LINEseed',
                ),
              ),
            ],
          ),
        );

        Widget connectNotice() => (!_connected!)
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
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontFamily: 'LINEseed',
                    ),
                  ),
                  subtitle: const Text(
                    '接続後にQRを作成できます。',
                    style: TextStyle(fontFamily: 'LINEseed'),
                  ),
                  trailing: FilledButton(
                    style: primary,
                    onPressed: () =>
                        startOnboarding(widget.tenantId, widget.tenantName!),
                    child: const Text(
                      '新規登録を完了する',
                      style: TextStyle(fontFamily: 'LINEseed'),
                    ),
                  ),
                ),
              )
            : const SizedBox.shrink();

        // 右側プレビュー：用紙変更時だけ再レイアウト（_paperVN）
        Widget previewPane() => ValueListenableBuilder<_Paper>(
          valueListenable: _paperVN,
          builder: (_, paper, __) {
            final def = _paperDefs[paper]!;
            final aspect = () {
              final wMm = _landscape ? def.heightMm : def.widthMm;
              final hMm = _landscape ? def.widthMm : def.heightMm;
              return wMm / hMm;
            }();

            return AspectRatio(
              aspectRatio: aspect,
              child: LayoutBuilder(
                builder: (context, c) {
                  final w = c.maxWidth;
                  final h = c.maxHeight;
                  final minSide = w < h ? w : h;

                  final widthMm = _landscape ? def.heightMm : def.widthMm;
                  final pxPerMm = w / widthMm;
                  final padPx = _qrPaddingMm * pxPerMm;
                  final qrSidePx = minSide * _qrScale;
                  final boxSidePx = qrSidePx + (_putWhiteBg ? padPx * 2 : 0);

                  final halfX = (boxSidePx / 2) / w;
                  final halfY = (boxSidePx / 2) / h;

                  final selected = options.firstWhere(
                    (o) => o.id == _selectedPosterId,
                  );
                  final posterWidget = selected.isAsset
                      ? Image.asset(selected.assetPath!, fit: BoxFit.cover)
                      : Image.network(selected.url!, fit: BoxFit.cover);

                  final left = _qrPos.dx * w - boxSidePx / 2;
                  final top = _qrPos.dy * h - boxSidePx / 2;

                  return _connected!
                      ? Stack(
                          children: [
                            Positioned.fill(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: posterWidget,
                              ),
                            ),
                            if (_publicStoreUrl != null)
                              Positioned(
                                left: left,
                                top: top,
                                width: boxSidePx,
                                height: boxSidePx,
                                child: GestureDetector(
                                  onPanUpdate: (details) {
                                    setState(() {
                                      final nx =
                                          (_qrPos.dx + details.delta.dx / w)
                                              .clamp(halfX, 1 - halfX);
                                      final ny =
                                          (_qrPos.dy + details.delta.dy / h)
                                              .clamp(halfY, 1 - halfY);
                                      _qrPos = Offset(nx, ny);
                                    });
                                  },
                                  onDoubleTap: () => setState(
                                    () => _qrPos = const Offset(0.5, 0.5),
                                  ),
                                  child: Container(
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
                                      border: Border.all(color: Colors.black12),
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
                        )
                      : Stack();
                },
              ),
            );
          },
        );

        final isWide = MediaQuery.of(context).size.width >= 900;

        if (isWide) {
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
                        if (_connected!) ...[
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
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                connectNotice(),
                if (_connected!) ...[
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
      title: Text(label, style: const TextStyle(color: Colors.black87)),
      subtitle: Slider(value: value, min: min, max: max, onChanged: onChanged),
      trailing: SizedBox(
        width: 56,
        child: Text(
          text,
          textAlign: TextAlign.end,
          style: const TextStyle(fontFamily: 'LINEseed'),
        ),
      ),
    );
  }
}
