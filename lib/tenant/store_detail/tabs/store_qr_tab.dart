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
import 'package:yourpay/tenant/method/fetchPlan.dart';
import 'package:yourpay/tenant/newTenant/onboardingSheet.dart';

class StoreQrTab extends StatefulWidget {
  final String tenantId;
  final String? tenantName;
  final String posterAssetPath; // 例: 'assets/posters/store_poster.png'
  final String? ownerId;
  const StoreQrTab({
    super.key,
    required this.tenantId,
    this.tenantName,

    this.posterAssetPath = 'assets/posters/store_poster.png',
    this.ownerId,
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
enum _Paper { a0, a1, a2, a3, a4, a6, a7, b0, b1, b2, b3, b4, b5, b6, b7 }

enum _QrDesign { classic, roundEyes, dots }

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
  // 追加: A6 / A7（A5は不要とのことなので未追加のまま）
  _Paper.a6: _PaperDef(
    'A6',
    PdfPageFormat(105 * PdfPageFormat.mm, 148 * PdfPageFormat.mm),
    105,
    148,
  ),
  _Paper.a7: _PaperDef(
    'A7',
    PdfPageFormat(74 * PdfPageFormat.mm, 105 * PdfPageFormat.mm),
    74,
    105,
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
  // 追加: B6 / B7
  _Paper.b6: _PaperDef(
    'B6',
    PdfPageFormat(125 * PdfPageFormat.mm, 176 * PdfPageFormat.mm),
    125,
    176,
  ),
  _Paper.b7: _PaperDef(
    'B7',
    PdfPageFormat(88 * PdfPageFormat.mm, 125 * PdfPageFormat.mm),
    88,
    125,
  ),
};

class _StoreQrTabState extends State<StoreQrTab> {
  final _functions = FirebaseFunctions.instanceFor(region: 'us-central1');

  final uid = FirebaseAuth.instance.currentUser?.uid;

  // ------- 状態 -------
  String? _publicStoreUrl;
  String _selectedPosterId = 'asset';
  _PosterOption? _optimisticPoster;

  // 表示/出力カスタム
  bool _putWhiteBg = true;
  double _qrScale = 0.35; // 20〜60%
  double _qrPaddingMm = 6;
  bool _landscape = false;
  // 追加: フィールド
  late CollectionReference<Map<String, dynamic>> _postersRef;
  Stream<QuerySnapshot<Map<String, dynamic>>>? _postersStream;
  QuerySnapshot<Map<String, dynamic>>? _initialPosters; // 初期表示用(キャッシュ)

  // 用紙：UI表示は setState、プレビューは _paperVN で用紙変更時のみ再描画
  _Paper _paper = _Paper.a4;
  final ValueNotifier<_Paper> _paperVN = ValueNotifier<_Paper>(_Paper.a4);

  Offset _qrPos = const Offset(0.5, 0.5);
  bool isC = false;
  _QrDesign _qrDesign = _QrDesign.classic;

  bool? _connected; // ← 一度だけ取得して保持

  @override
  void initState() {
    super.initState();
    _publicStoreUrl = _buildStoreUrl();

    final u = FirebaseAuth.instance.currentUser?.uid;
    assert(u != null, 'Not signed in');
    _postersRef = FirebaseFirestore.instance
        .collection(widget.ownerId!)
        .doc(widget.tenantId)
        .collection('posters');

    _postersStream = _postersRef.snapshots(); // ← 初回から張る

    _primeInitialPosters(); // ← 下の #2 参照
    _loadConnectedOnce();
    _initialize();
  }

  @override
  void didUpdateWidget(covariant StoreQrTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tenantId != widget.tenantId) {
      _publicStoreUrl = _buildStoreUrl();
      _qrPos = const Offset(0.5, 0.5);

      final u = FirebaseAuth.instance.currentUser?.uid;
      _postersRef = FirebaseFirestore.instance
          .collection(widget.ownerId!)
          .doc(widget.tenantId)
          .collection('posters');

      setState(() {
        _postersStream = _postersRef.snapshots(); // ★ 張り替え
        _optimisticPoster = null;
        _selectedPosterId = 'asset';
      });

      _primeInitialPosters(); // ★ 新テナントの初期データも取り直す
      _loadConnectedOnce();
      _initialize();
    }
  }

  Future<void> _initialize() async {
    final c = await fetchIsCPlan(
      FirebaseFirestore.instance
          .collection(widget.ownerId!)
          .doc(widget.tenantId),
    );
    if (!mounted) return;
    setState(() => isC = c); // ★ 取得後に描画更新
  }

  Future<void> _loadConnectedOnce() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection(widget.ownerId!)
          .doc(widget.tenantId)
          .get();
      final c = (doc.data()?['connect']?['charges_enabled'] as bool?) ?? false;
      if (mounted) setState(() => _connected = c);
    } catch (_) {
      if (mounted) setState(() => _connected = false);
    }
  }

  Future<void> _primeInitialPosters() async {
    try {
      final snap = await _postersRef.get(
        const GetOptions(source: Source.cache),
      );
      if (mounted && (snap.docs.isNotEmpty)) {
        setState(() => _initialPosters = snap);
      }
    } catch (_) {
      // キャッシュが無い・失敗は無視でOK
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

      // ★ ストリーム到着前に一時的に UI に出す
      _optimisticPoster = _PosterOption.remote(docRef.id, url, label: f.name);

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

    // previewPane() の中（ValueListenableBuilder の builder 内）
    final selected = options.firstWhere(
      (o) => o.id == _selectedPosterId,
      orElse: () => options.first, // ★ 追加：見つからなければ先頭（テンプレ）を使う
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

    final waitingConnect = _connected == null;

    // ---------------- UI ----------------
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _postersStream,
      initialData: _initialPosters,
      builder: (context, postersSnap) {
        // ★ 読み込みエラーは画面にも出し、SnackBar でも通知
        if (postersSnap.hasError) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('ポスターの読み込みに失敗しました: ${postersSnap.error}'),
                ),
              );
            }
          });
        }

        final remoteDocs = (postersSnap.data?.docs ?? []);
        final options = <_PosterOption>[
          _PosterOption.asset(widget.posterAssetPath, label: 'テンプレ'),
          ...remoteDocs.map((d) {
            final m = d.data();
            return _PosterOption.remote(
              d.id,
              (m['url'] ?? '') as String,
              label: (m['name'] ?? 'ポスター') as String,
            );
          }),
        ];

        // ★ 楽観挿入の重複防止：同じIDがサーバーから来たら破棄
        if (_optimisticPoster != null &&
            options.any((o) => o.id == _optimisticPoster!.id)) {
          _optimisticPoster = null;
        }

        // ★ まだ入っていなければ一時的に挿入（アップロード直後にすぐ見える）
        if (_optimisticPoster != null &&
            !options.any((o) => o.id == _optimisticPoster!.id)) {
          options.insert(1, _optimisticPoster!);
        }

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
                '横向き',
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

        Widget uploadButton({required bool isC}) {
          final canUpload = (_connected ?? false) && isC;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              OutlinedButton.icon(
                onPressed: canUpload ? _addPosterFromFile : null,
                icon: const Icon(Icons.add_photo_alternate_outlined),
                label: const Text(
                  'アップロード',
                  style: TextStyle(fontFamily: 'LINEseed'),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: black78,
                  side: const BorderSide(color: Colors.black54),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                ),
              ),
              if (!isC)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'ポスターをカスタムしたい場合はサブスクリプションをCプランに変更してください',
                    style: TextStyle(
                      color: Colors.black87,
                      fontFamily: 'LINEseed',
                    ),
                  ),
                ),
            ],
          );
        }

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
                              : Image.network(
                                  opt.url!,
                                  fit: BoxFit.cover,
                                  loadingBuilder: (ctx, child, progress) =>
                                      progress == null
                                      ? child
                                      : const Center(
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        ),
                                  errorBuilder: (ctx, err, st) => const Center(
                                    child: Icon(Icons.broken_image),
                                  ),
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
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('QRデザイン'),
                trailing: DropdownButton<_QrDesign>(
                  value: _qrDesign,
                  onChanged: (v) => setState(() => _qrDesign = v!),
                  items: const [
                    DropdownMenuItem(
                      value: _QrDesign.classic,
                      child: Text('デフォルト（四角）'),
                    ),
                    DropdownMenuItem(
                      value: _QrDesign.roundEyes,
                      child: Text('丸い目＋四角ドット'),
                    ),
                    DropdownMenuItem(
                      value: _QrDesign.dots,
                      child: Text('丸ドット'),
                    ),
                  ],
                ),
              ),
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
            final wMm = _landscape ? def.heightMm : def.widthMm;
            final hMm = _landscape ? def.widthMm : def.heightMm;
            final aspect = wMm / hMm;

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
                    orElse: () => options.first,
                  );
                  final posterWidget = selected.isAsset
                      ? Image.asset(selected.assetPath!, fit: BoxFit.cover)
                      : Image.network(selected.url!, fit: BoxFit.cover);

                  final left = _qrPos.dx * w - boxSidePx / 2;
                  final top = _qrPos.dy * h - boxSidePx / 2;

                  final showQr =
                      _publicStoreUrl != null && _publicStoreUrl!.isNotEmpty;

                  // ★ ここを必ず return する！
                  return Stack(
                    children: [
                      Positioned.fill(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: posterWidget,
                        ),
                      ),
                      if (showQr)
                        Positioned(
                          left: left,
                          top: top,
                          width: boxSidePx,
                          height: boxSidePx,
                          child: GestureDetector(
                            onPanUpdate: (details) {
                              setState(() {
                                final nx = (_qrPos.dx + details.delta.dx / w)
                                    .clamp(halfX, 1 - halfX)
                                    .toDouble(); // ★ clamp の戻り値を double に
                                final ny = (_qrPos.dy + details.delta.dy / h)
                                    .clamp(halfY, 1 - halfY)
                                    .toDouble();
                                _qrPos = Offset(nx, ny);
                              });
                            },
                            onDoubleTap: () =>
                                setState(() => _qrPos = const Offset(0.5, 0.5)),
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
                                  eyeStyle: QrEyeStyle(
                                    color: Colors.black,
                                    eyeShape:
                                        _qrDesign == _QrDesign.dots ||
                                            _qrDesign == _QrDesign.roundEyes
                                        ? QrEyeShape.circle
                                        : QrEyeShape.square,
                                  ),
                                  dataModuleStyle: QrDataModuleStyle(
                                    color: Colors.black,
                                    dataModuleShape: _qrDesign == _QrDesign.dots
                                        ? QrDataModuleShape.circle
                                        : QrDataModuleShape.square,
                                  ),
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
                              Expanded(child: uploadButton(isC: isC)),
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
                _connected!
                    ? Expanded(
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: previewPane(),
                        ),
                      )
                    : Expanded(
                        child: Center(
                          child: Text("初期登録を終えると、QRコードを含んだポスターを作成することができます。"),
                        ),
                      ),
              ],
            ),
          );
        } else {
          if (waitingConnect) const LinearProgressIndicator(minHeight: 2);
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (waitingConnect)
                  const LinearProgressIndicator(minHeight: 2), // ← こう
                connectNotice(),
                if (_connected!) ...[
                  paperSelector(),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(child: pdfButton()),
                      const SizedBox(width: 12),
                      Expanded(child: uploadButton(isC: isC)),
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
