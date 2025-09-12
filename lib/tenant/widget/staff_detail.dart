// lib/tenant/store_detail/staff_detail_screen.dart
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:yourpay/tenant/method/fetchPlan.dart';
import 'package:yourpay/tenant/widget/upload_video.dart';

class StaffDetailScreen extends StatefulWidget {
  final String tenantId;
  final String employeeId;
  const StaffDetailScreen({
    super.key,
    required this.tenantId,
    required this.employeeId,
  });

  @override
  State<StaffDetailScreen> createState() => _StaffDetailScreenState();
}

class _StaffDetailScreenState extends State<StaffDetailScreen> {
  final _nameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _commentCtrl = TextEditingController();
  final uid = FirebaseAuth.instance.currentUser?.uid;

  Uint8List? _newPhotoBytes;
  String? _newPhotoName;
  bool _saving = false;
  String _plan = 'UNKNOWN';

  @override
  void initState() {
    super.initState();
    fetchPlanStringById(uid!, widget.tenantId).then((p) {
      if (!mounted) return;
      setState(() => _plan = p);
    });
  }

  // 公開ページのベースURL（末尾スラなし）
  static const String _publicBase =
      'https://venerable-mermaid-fcf8c8.netlify.app';

  String _staffTipUrl(String tenantId, String employeeId, {int? initAmount}) {
    final qp = <String, String>{
      'u': uid!,
      't': tenantId,
      'e': employeeId,
      if (initAmount != null) 'a': '$initAmount',
    };
    final query = Uri(queryParameters: qp).query;
    return '$_publicBase/#/staff?$query';
  }

  Future<void> _pickNewPhoto() async {
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
      _newPhotoBytes = bytes;
      _newPhotoName = f.name;
    });
  }

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

  Future<void> _save(
    DocumentReference<Map<String, dynamic>> empRef,
    Map<String, dynamic> current,
  ) async {
    final name = _nameCtrl.text.trim();
    final email = _emailCtrl.text.trim();
    final comment = _commentCtrl.text.trim();

    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.white,
          content: const Text(
            '名前は必須です',
            style: TextStyle(color: Colors.black87),
          ),
        ),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      String? photoUrl = current['photoUrl'] as String?;
      if (_newPhotoBytes != null) {
        final contentType = _detectContentType(_newPhotoName);
        final ext = contentType.split('/').last;
        final storageRef = FirebaseStorage.instance.ref().child(
          '${uid}/${widget.tenantId}/employees/${widget.employeeId}/photo.$ext',
        );
        await storageRef.putData(
          _newPhotoBytes!,
          SettableMetadata(contentType: contentType),
        );
        photoUrl = await storageRef.getDownloadURL();
      }

      await empRef.set({
        'name': name,
        'email': email,
        'comment': comment,
        if (photoUrl != null) 'photoUrl': photoUrl,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Colors.white,
            content: Text('保存しました', style: TextStyle(color: Colors.black87)),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.white,
            content: Text(
              '保存に失敗: $e',
              style: const TextStyle(color: Colors.black87),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // 白カードの共通ラッパー
  Widget _whiteCard(Widget child) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 10,
            offset: Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: child,
    );
  }

  InputDecoration _inputDeco(String label, {String? hint}) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: Colors.black87), // ★ 統一
      hintText: hint,
      hintStyle: const TextStyle(color: Colors.black87), // ★ 統一
      filled: true,
      fillColor: Colors.white,
      isDense: true,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    );
  }

  @override
  Widget build(BuildContext context) {
    final empRef = FirebaseFirestore.instance
        .collection(uid!)
        .doc(widget.tenantId)
        .collection('employees')
        .doc(widget.employeeId);

    // ボタンも黒87テキストに統一（背景は白／枠あり）
    final blackButton = FilledButton.styleFrom(
      backgroundColor: Colors.white,
      foregroundColor: Colors.black87,
      side: const BorderSide(color: Colors.black54),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    );

    final outlineButton = OutlinedButton.styleFrom(
      foregroundColor: Colors.black87,
      side: const BorderSide(color: Colors.black87),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    );

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: empRef.snapshots(),
      builder: (context, snap) {
        if (snap.hasError) {
          return Scaffold(
            backgroundColor: const Color(0xFFF7F7F7),
            appBar: AppBar(
              backgroundColor: Colors.white,
              foregroundColor: Colors.black87,
              elevation: 0,
              title: const Text(
                'スタッフ詳細',
                style: TextStyle(color: Colors.black87),
              ),
            ),
            body: const Center(
              child: Text('読み込みエラー', style: TextStyle(color: Colors.black87)),
            ),
          );
        }
        if (!snap.hasData) {
          return const Scaffold(
            backgroundColor: Color(0xFFF7F7F7),
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final data = snap.data!.data();
        if (data == null) {
          return Scaffold(
            backgroundColor: const Color(0xFFF7F7F7),
            appBar: AppBar(
              backgroundColor: Colors.white,
              foregroundColor: Colors.black87,
              elevation: 0,
              title: const Text(
                'スタッフ詳細',
                style: TextStyle(color: Colors.black87),
              ),
            ),
            body: const Center(
              child: Text(
                '該当データが見つかりません',
                style: TextStyle(color: Colors.black87),
              ),
            ),
          );
        }

        // フォーム初期値
        _nameCtrl.value = TextEditingValue(
          text: (data['name'] ?? '') as String,
        );
        _emailCtrl.value = TextEditingValue(
          text: (data['email'] ?? '') as String,
        );
        _commentCtrl.value = TextEditingValue(
          text: (data['comment'] ?? '') as String,
        );

        final photoUrl = (data['photoUrl'] ?? '') as String;
        final tipUrl = _staffTipUrl(widget.tenantId, widget.employeeId);

        return Scaffold(
          backgroundColor: const Color(0xFFF7F7F7), // 薄いグレー（白基調）
          appBar: AppBar(
            backgroundColor: Colors.white,
            foregroundColor: Colors.black87,
            elevation: 0,
            title: const Text(
              'スタッフ詳細・編集',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 15,
                color: Colors.black87, // ★ 統一
              ),
            ),
            actions: const [],
          ),
          body: Theme(
            data: Theme.of(context).copyWith(
              textTheme: Theme.of(context).textTheme.apply(
                bodyColor: Colors.black87,
                displayColor: Colors.black87,
              ),
            ),
            child: DefaultTextStyle.merge(
              style: const TextStyle(color: Colors.black87),
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // 顔写真 & 基本情報
                  _whiteCard(
                    Column(
                      children: [
                        GestureDetector(
                          onTap: _saving ? null : _pickNewPhoto,
                          child: CircleAvatar(
                            radius: 48,
                            backgroundImage: _newPhotoBytes != null
                                ? MemoryImage(_newPhotoBytes!)
                                : (photoUrl.isNotEmpty
                                          ? NetworkImage(photoUrl)
                                          : null)
                                      as ImageProvider<Object>?,
                            child: (_newPhotoBytes == null && photoUrl.isEmpty)
                                ? const Icon(Icons.camera_alt, size: 28)
                                : null,
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: _nameCtrl,
                          decoration: _inputDeco('名前（必須）'),
                          style: const TextStyle(color: Colors.black87),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _emailCtrl,
                          decoration: _inputDeco(
                            'メールアドレス（任意） *メールアドレスを登録すると、チップ受け取り時にメールが届きます。',
                          ),
                          style: const TextStyle(color: Colors.black87),
                          keyboardType: TextInputType.emailAddress,
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _commentCtrl,
                          decoration: _inputDeco(
                            'コメント（任意）',
                            hint: '得意分野や紹介文など',
                          ),
                          style: const TextStyle(color: Colors.black87),
                          maxLines: 3,
                        ),
                        const SizedBox(height: 12),
                        Align(
                          alignment: Alignment.centerRight,
                          child: FilledButton(
                            style: blackButton,
                            onPressed: _saving
                                ? null
                                : () => _save(empRef, data),
                            child: _saving
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Text(
                                    '保存する',
                                    style: TextStyle(color: Colors.black87),
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  if (_plan == "C")
                    StaffThanksVideoManager(
                      tenantId: widget.tenantId,
                      staffId: widget.employeeId,
                    ),

                  const SizedBox(height: 16),

                  // QRコードセクション
                  _whiteCard(
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'スタッフ用QRコード',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: Colors.black87,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Center(child: QrImageView(data: tipUrl, size: 180)),
                        const SizedBox(height: 8),
                        SelectableText(
                          tipUrl,
                          style: const TextStyle(color: Colors.black87),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          children: [
                            OutlinedButton.icon(
                              style: outlineButton,
                              onPressed: () => launchUrlString(
                                tipUrl,
                                mode: LaunchMode.externalApplication,
                              ),
                              icon: const Icon(Icons.open_in_new),
                              label: const Text(
                                'リンクを開く',
                                style: TextStyle(color: Colors.black87),
                              ),
                            ),
                            OutlinedButton.icon(
                              style: outlineButton,
                              onPressed: () async {
                                await Clipboard.setData(
                                  ClipboardData(text: tipUrl),
                                );
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      backgroundColor: Colors.white,
                                      content: Text(
                                        'URLをコピーしました',
                                        style: TextStyle(color: Colors.black87),
                                      ),
                                    ),
                                  );
                                }
                              },
                              icon: const Icon(Icons.copy),
                              label: const Text(
                                'URLをコピー',
                                style: TextStyle(color: Colors.black87),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
