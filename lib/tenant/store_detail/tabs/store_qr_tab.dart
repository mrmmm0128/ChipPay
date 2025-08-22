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

class _StoreQrTabState extends State<StoreQrTab> {
  final _functions = FirebaseFunctions.instanceFor(region: 'us-central1');

  String? _publicStoreUrl;
  String _selectedPosterId = 'asset'; // 既定はアセット

  String _buildStoreUrl() {
    final origin = kIsWeb ? Uri.base.origin : Uri.base.origin;
    return '$origin/#/p?t=${widget.tenantId}';
  }

  void _makeQr() => setState(() => _publicStoreUrl = _buildStoreUrl());

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

      // contentType 推定
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
      // printing の networkImage を使うと簡単に PDF 用プロバイダが取れます
      posterProvider = await networkImage(selected.url!);
    }

    final doc = pw.Document();
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (ctx) {
          final pageW = ctx.page.pageFormat.availableWidth;
          final pageH = ctx.page.pageFormat.availableHeight;
          final qrSize = (pageW < pageH ? pageW : pageH) * 0.32;

          return pw.Center(
            child: pw.Stack(
              alignment: pw.Alignment.center,
              children: [
                pw.FittedBox(
                  child: pw.Image(posterProvider),
                  fit: pw.BoxFit.contain,
                ),
                pw.SizedBox(
                  width: qrSize,
                  height: qrSize,
                  child: pw.BarcodeWidget(
                    barcode: Barcode.qrCode(),
                    data: _publicStoreUrl!,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );

    await Printing.layoutPdf(onLayout: (_) async => doc.save());
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
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    );

    // テナントの Stripe 接続状況
    final tenantDocStream = FirebaseFirestore.instance
        .collection('tenants')
        .doc(widget.tenantId)
        .snapshots();

    // 永続化したポスター一覧
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
            // 一覧のビルド（アセット + リモート）
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

            // 選択IDが無効になった場合のフォールバック
            if (!options.any((o) => o.id == _selectedPosterId)) {
              _selectedPosterId = options.first.id;
            }

            return SingleChildScrollView(
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
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: const Text('接続後にQRを作成できます。'),
                        trailing: FilledButton(
                          style: primary,
                          onPressed: _openOnboarding,
                          child: Text(hasAccount ? '続きから再開' : 'Stripeに接続'),
                        ),
                      ),
                    ),
                  const SizedBox(height: 12),

                  // アクション
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      FilledButton.icon(
                        style: primary,
                        onPressed: connected ? _makeQr : null,
                        icon: const Icon(Icons.qr_code_2),
                        label: const Text('QRコードを作成/更新'),
                      ),
                      FilledButton.icon(
                        style: primary,
                        onPressed: (connected && _publicStoreUrl != null)
                            ? () => _exportPdf(options)
                            : null,
                        icon: const Icon(Icons.picture_as_pdf),
                        label: const Text('PDFに出力'),
                      ),
                      OutlinedButton.icon(
                        onPressed: connected ? _addPosterFromFile : null,
                        icon: const Icon(Icons.add_photo_alternate_outlined),
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
                      ),
                    ],
                  ),

                  const SizedBox(height: 16),
                  Text(
                    'ポスターを選択',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),

                  // サムネ（横スクロール）
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

                  const SizedBox(height: 16),

                  // プレビュー（中央にQR）
                  AspectRatio(
                    aspectRatio: 3 / 4,
                    child: LayoutBuilder(
                      builder: (context, c) {
                        final qrSide = c.maxWidth * 0.35;
                        final selected = options.firstWhere(
                          (o) => o.id == _selectedPosterId,
                        );
                        final posterWidget = selected.isAsset
                            ? Image.asset(
                                selected.assetPath!,
                                fit: BoxFit.cover,
                              )
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
                              SizedBox(
                                width: qrSide,
                                height: qrSide,
                                child: QrImageView(data: _publicStoreUrl!),
                              ),
                            if (!connected)
                              Container(
                                color: Colors.white.withOpacity(0.6),
                                alignment: Alignment.center,
                                child: const Text(
                                  'Stripe接続が完了するとQRを表示できます',
                                  style: TextStyle(fontWeight: FontWeight.w600),
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
                ],
              ),
            );
          },
        );
      },
    );
  }
}
