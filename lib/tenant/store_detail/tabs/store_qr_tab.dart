// lib/tenant/store_detail/tabs/store_qr_tab.dart
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
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

  /// ★ 追加：QR の位置（正規化座標 0〜1）。dx=横、dy=縦。中央スタート。
  Offset _qrPos = const Offset(0.5, 0.5);
  final uid = FirebaseAuth.instance.currentUser?.uid;

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
        _qrPos = const Offset(0.5, 0.5); // テナント変更時は中央にリセット（任意）
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
          .collection(uid!)
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
      posterProvider = await networkImage(selected.url!); // from printing
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
          final boxSidePt = qrSidePt + (_putWhiteBg ? padPt * 2 : 0);

          // 正規化座標 -> PDF座標に変換（はみ出しクランプ）
          double leftPt = _qrPos.dx * pageW - boxSidePt / 2;
          double topPt = _qrPos.dy * pageH - boxSidePt / 2;
          leftPt = leftPt.clamp(0, pageW - boxSidePt);
          topPt = topPt.clamp(0, pageH - boxSidePt);

          final poster = pw.Positioned.fill(
            child: pw.FittedBox(
              child: pw.Image(posterProvider),
              fit: pw.BoxFit.cover, // プレビューと合わせる
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

  // ---------- オンボーディング（モーダル/ステッパー） ----------
  Future<void> startOnboarding(String tenantId, String tenantName) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true, // シートを大きくできる（DraggableScrollableSheetに最適）
      isDismissible: false, // 外側タップで閉じない
      enableDrag: false, // 引っ張っても閉じない
      useRootNavigator: true, // ルートNavigatorで全画面を覆う（ネスト対策）
      barrierColor: Colors.black38, // 半透明バリア（背面をブロック）
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetCtx) {
        // ★ 紫対策：ボトムシート全体を白黒テーマで包む
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

  // ---- ここが肝：白×黒テーマ（ポップアップ用のローカルテーマ）----
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
  Widget build(BuildContext context) {
    final black78 = Colors.black.withOpacity(0.78); // 統一色
    final primary = FilledButton.styleFrom(
      backgroundColor: Colors.white,
      foregroundColor: black78,
      side: const BorderSide(color: Colors.black54),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    );

    final tenantDocStream = FirebaseFirestore.instance
        .collection(uid!)
        .doc(widget.tenantId)
        .snapshots();

    final postersStream = FirebaseFirestore.instance
        .collection(uid!)
        .doc(widget.tenantId)
        .collection('posters')
        .orderBy('createdAt', descending: true)
        .snapshots();

    return StreamBuilder<DocumentSnapshot>(
      stream: tenantDocStream,
      builder: (context, tenantSnap) {
        final data = tenantSnap.data?.data() as Map<String, dynamic>?;

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
                );

                Widget posterPicker() => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'ポスターを選択',
                      style: Theme.of(
                        context,
                      ).textTheme.titleMedium?.copyWith(color: black78),
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
                        style: TextStyle(fontSize: 12, color: black78),
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
                          style: TextStyle(color: Colors.black87),
                        ),
                        value: _putWhiteBg,
                        onChanged: (v) => setState(() => _putWhiteBg = v),
                        contentPadding: EdgeInsets.zero,
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'ヒント：プレビュー内のQRをドラッグで移動／ダブルタップで中央に戻せます。',
                        style: TextStyle(fontSize: 12, color: Colors.black54),
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
                            onPressed: () => startOnboarding(
                              widget.tenantId,
                              widget.tenantName!,
                            ),
                            child: Text("新規登録を完"),
                          ),
                        ),
                      )
                    : const SizedBox.shrink();

                // 右側プレビュー（ドラッグ対応版）
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

                      // 端からはみ出さないための中心位置の許容域
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

                      return Stack(
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
      title: Text(label, style: const TextStyle(color: Colors.black87)),
      subtitle: Slider(value: value, min: min, max: max, onChanged: onChanged),
      trailing: SizedBox(
        width: 56,
        child: Text(text, textAlign: TextAlign.end),
      ),
    );
  }
}
