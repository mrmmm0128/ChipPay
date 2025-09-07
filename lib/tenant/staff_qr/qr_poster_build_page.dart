// lib/public/qr_poster_builder_page.dart
import 'dart:typed_data';
import 'package:barcode/barcode.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import 'package:qr_flutter/qr_flutter.dart'; // プレビュー用QR

class QrPosterBuilderPage extends StatefulWidget {
  const QrPosterBuilderPage({super.key});

  @override
  State<QrPosterBuilderPage> createState() => _QrPosterBuilderPageState();
}

// ===== 用紙定義（縦基準の寸法・フォーマット） =====
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

class _QrPosterBuilderPageState extends State<QrPosterBuilderPage> {
  String? tenantId;
  String? employeeId;

  Uint8List? _photoBytes;
  String? _photoName;

  double _qrSizeMm = 50; // QRサイズ（mm）
  double _marginMm = 12; // 余白（mm）（PDF用に残しておく）
  bool _putWhiteBg = true; // QRの白背景

  // 追加: 用紙と向き
  _Paper _paper = _Paper.a4;
  bool _landscape = false; // 横向き

  // ローカル/本番自動切替のベースURL
  String get _publicBase {
    final u = Uri.base;
    final isHttp =
        (u.scheme == 'http' || u.scheme == 'https') && u.host.isNotEmpty;
    if (isHttp) {
      return '${u.scheme}://${u.host}${u.hasPort ? ':${u.port}' : ''}';
    }
    const fb = String.fromEnvironment(
      'PUBLIC_BASE',
      defaultValue: 'https://venerable-mermaid-fcf8c8.netlify.app',
    );
    return fb;
  }

  @override
  void initState() {
    super.initState();
    _initFromUrl();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is Map) {
      tenantId ??= (args['tenantId'] ?? args['t'])?.toString();
      employeeId ??= (args['employeeId'] ?? args['e'])?.toString();
      setState(() {});
    }
  }

  void _initFromUrl() {
    final uri = Uri.base;
    final frag = uri.fragment; // "#/qr-builder?t=...&e=..."
    final qi = frag.indexOf('?');
    final qp = <String, String>{}..addAll(uri.queryParameters);
    if (qi >= 0) {
      qp.addAll(Uri.splitQueryString(frag.substring(qi + 1)));
    }
    tenantId = qp['t'] ?? qp['tenantId'];
    employeeId = qp['e'] ?? qp['employeeId'];
    setState(() {});
  }

  String get _qrData {
    if (tenantId == null || employeeId == null) return '';
    final params = Uri(
      queryParameters: {'t': tenantId!, 'e': employeeId!},
    ).query;
    return '$_publicBase/#/staff?$params';
  }

  Future<void> _pickPhoto() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
      withData: true,
    );
    if (res == null || res.files.isEmpty) return;
    final f = res.files.single;
    Uint8List? bytes = f.bytes;
    if (bytes == null && f.readStream != null) {
      final chunks = <int>[];
      await for (final c in f.readStream!) {
        chunks.addAll(c);
      }
      bytes = Uint8List.fromList(chunks);
    }
    if (bytes == null) return;
    setState(() {
      _photoBytes = bytes;
      _photoName = f.name;
    });
  }

  Future<void> _makePdfAndDownload() async {
    if (_qrData.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('URLが不正です', style: TextStyle(fontFamily: 'LINEseed')),
        ),
      );
      return;
    }

    final pdf = pw.Document();

    // mm → pt
    double mm(double v) => v * PdfPageFormat.mm;

    // ページフォーマット（向き対応）
    final pdef = _paperDefs[_paper]!;
    final pageFormat = _landscape ? pdef.format.landscape : pdef.format;

    // 背景
    pw.Widget background = pw.Container(color: PdfColors.white);
    if (_photoBytes != null) {
      final img = pw.MemoryImage(_photoBytes!);
      background = pw.Positioned.fill(
        child: pw.Image(img, fit: pw.BoxFit.cover),
      );
    }

    // QR（PDF用）
    final barcode = Barcode.qrCode();
    final qrWidget = pw.BarcodeWidget(
      barcode: barcode,
      data: _qrData,
      width: mm(_qrSizeMm),
      height: mm(_qrSizeMm),
      drawText: false,
      color: PdfColors.black,
    );

    final qrBox = pw.Container(
      width: mm(_qrSizeMm + (_putWhiteBg ? 10 : 0)),
      height: mm(_qrSizeMm + (_putWhiteBg ? 10 : 0)),
      decoration: _putWhiteBg
          ? pw.BoxDecoration(
              color: PdfColors.white,
              borderRadius: pw.BorderRadius.circular(6),
            )
          : const pw.BoxDecoration(),
      alignment: pw.Alignment.center,
      child: qrWidget,
    );

    pdf.addPage(
      pw.Page(
        pageFormat: pageFormat,
        build: (_) => pw.Stack(
          children: [
            background,
            pw.Center(child: qrBox), // 常に中央
          ],
        ),
      ),
    );

    final fname = 'staff_qr_${employeeId ?? ""}.pdf';
    await Printing.sharePdf(bytes: await pdf.save(), filename: fname);
  }

  @override
  Widget build(BuildContext context) {
    final valid = tenantId != null && employeeId != null;

    // プレビューのアスペクト比（向き対応）
    final pdef = _paperDefs[_paper]!;
    final previewAspect = _landscape
        ? (pdef.heightMm / pdef.widthMm) /*= 297/210 等*/
        : (pdef.widthMm / pdef.heightMm) /*= 210/297 等*/;

    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 0,
        title: const Text(
          'QRポスター作成',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontFamily: 'LINEseed',
            fontSize: 16,
          ),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              // ▼ 用紙サイズ・向き
              Row(
                children: [
                  Expanded(
                    child: InputDecorator(
                      decoration: InputDecoration(
                        labelText: '用紙サイズ',
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
                          items: _paperDefs.entries
                              .map(
                                (e) => DropdownMenuItem(
                                  value: e.key,
                                  child: Text(
                                    e.value.label,
                                    style: TextStyle(fontFamily: 'LINEseed'),
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: (v) => setState(() => _paper = v!),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: InputDecorator(
                      decoration: InputDecoration(
                        labelText: '向き',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<bool>(
                          value: _landscape,
                          items: const [
                            DropdownMenuItem(
                              value: false,
                              child: Text(
                                '縦向き',
                                style: TextStyle(fontFamily: 'LINEseed'),
                              ),
                            ),
                            DropdownMenuItem(
                              value: true,
                              child: Text(
                                '横向き',
                                style: TextStyle(fontFamily: 'LINEseed'),
                              ),
                            ),
                          ],
                          onChanged: (v) => setState(() => _landscape = v!),
                        ),
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 12),

              if (!valid)
                const Text(
                  'URLが不正です（t/e パラメータが必要）',
                  style: TextStyle(fontFamily: 'LINEseed'),
                ),

              if (valid) ...[
                // プレビュー（用紙・向きに追従）
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x14000000),
                        blurRadius: 10,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                  padding: const EdgeInsets.all(12),
                  child: AspectRatio(
                    aspectRatio: previewAspect,
                    child: LayoutBuilder(
                      builder: (context, c) {
                        // mm→px 換算は「ページの幅mm」に合わせる
                        final widthMm = _landscape
                            ? pdef.heightMm
                            : pdef.widthMm;
                        final pxPerMm = c.maxWidth / widthMm;
                        final qrPx =
                            (_qrSizeMm + (_putWhiteBg ? 10 : 0)) * pxPerMm;

                        return Stack(
                          children: [
                            Positioned.fill(
                              child: _photoBytes == null
                                  ? Container(
                                      color: Colors.black12,
                                      child: const Center(
                                        child: Text(
                                          '写真なし',
                                          style: TextStyle(
                                            fontFamily: 'LINEseed',
                                          ),
                                        ),
                                      ),
                                    )
                                  : Image.memory(
                                      _photoBytes!,
                                      fit: BoxFit.cover,
                                    ),
                            ),
                            Align(
                              alignment: Alignment.center,
                              child: Container(
                                width: qrPx,
                                height: qrPx,
                                decoration: BoxDecoration(
                                  color: _putWhiteBg
                                      ? Colors.white
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(6),
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
                                child: _qrData.isEmpty
                                    ? const SizedBox()
                                    : Center(
                                        child: QrImageView(
                                          data: _qrData,
                                          version: QrVersions.auto,
                                          gapless: true,
                                          size: qrPx - (_putWhiteBg ? 12 : 0),
                                        ),
                                      ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),

                const SizedBox(height: 12),

                // コントロール群
                LayoutBuilder(
                  builder: (context, c) {
                    final narrow = c.maxWidth < 560;
                    final pickBtn = Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _pickPhoto,
                        icon: const Icon(Icons.photo_library),
                        label: Text(
                          _photoName ?? '写真を選ぶ',
                          style: TextStyle(fontFamily: 'LINEseed'),
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.black87,
                          side: const BorderSide(color: Colors.black87),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    );
                    final pdfBtn = FilledButton.icon(
                      onPressed: _makePdfAndDownload,
                      icon: const Icon(Icons.file_download),
                      label: const Text(
                        'PDFをダウンロード',
                        style: TextStyle(fontFamily: 'LINEseed'),
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.black,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    );
                    if (narrow) {
                      return Column(
                        children: [
                          Row(children: [pickBtn]),
                          const SizedBox(height: 8),
                          SizedBox(width: double.infinity, child: pdfBtn),
                        ],
                      );
                    } else {
                      return Row(
                        children: [pickBtn, const SizedBox(width: 8), pdfBtn],
                      );
                    }
                  },
                ),

                const SizedBox(height: 12),
                _SliderTile(
                  label: 'QRサイズ (mm)',
                  value: _qrSizeMm,
                  min: 30,
                  max: 120,
                  onChanged: (v) => setState(() => _qrSizeMm = v),
                ),
                _SliderTile(
                  label: '余白 (mm)',
                  value: _marginMm,
                  min: 0,
                  max: 40,
                  onChanged: (v) => setState(() => _marginMm = v),
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
                const SizedBox(height: 24),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SliderTile extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  const _SliderTile({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      textColor: Colors.black87,
      title: Text(
        label,
        style: TextStyle(color: Colors.black87, fontFamily: 'LINEseed'),
      ),
      subtitle: Slider(value: value, min: min, max: max, onChanged: onChanged),
      trailing: SizedBox(
        width: 56,
        child: Text(
          value.toStringAsFixed(0),
          style: TextStyle(fontFamily: 'LINEseed'),
        ),
      ),
    );
  }
}
