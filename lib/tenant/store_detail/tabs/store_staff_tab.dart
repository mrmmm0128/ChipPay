// tabs/staff_tab.dart
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // クリップボード
import 'package:url_launcher/url_launcher_string.dart'; // 外部リンク
import 'package:yourpay/tenant/store_detail/staff_detail.dart';
import 'package:yourpay/tenant/store_detail/staff_entry.dart';

class StoreStaffTab extends StatefulWidget {
  final String tenantId;
  const StoreStaffTab({super.key, required this.tenantId});

  @override
  State<StoreStaffTab> createState() => _StoreStaffTabState();
}

class _StoreStaffTabState extends State<StoreStaffTab> {
  final _empNameCtrl = TextEditingController();
  final _empEmailCtrl = TextEditingController();
  final _empCommentCtrl = TextEditingController();
  Uint8List? _empPhotoBytes;
  String? _empPhotoName;
  bool _addingEmp = false;

  // 公開ページのベースURL（末尾スラなし）
  String get _publicBase {
    final u = Uri.base; // 例: http://localhost:5173/#/qr-all?t=...
    final isHttp =
        (u.scheme == 'http' || u.scheme == 'https') && u.host.isNotEmpty;
    if (isHttp) {
      // 例: http://localhost:5173 / https://example.app
      return '${u.scheme}://${u.host}${u.hasPort ? ':${u.port}' : ''}';
    }
    // モバイル/テスト等で Uri.base が使えない時のフォールバック
    const fallback = String.fromEnvironment(
      'PUBLIC_BASE',
      defaultValue: 'https://venerable-mermaid-fcf8c8.netlify.app',
    );
    return fallback;
  }

  String _allStaffUrl() => '$_publicBase/#/qr-all?t=${widget.tenantId}';

  @override
  void dispose() {
    _empNameCtrl.dispose();
    _empEmailCtrl.dispose();
    _empCommentCtrl.dispose();
    super.dispose();
  }

  bool _validateEmail(String v) {
    final s = v.trim();
    if (s.isEmpty) return false;
    return s.contains('@') && s.contains('.');
  }

  Future<void> _openAddEmployeeDialog() async {
    _empPhotoBytes = null;
    _empPhotoName = null;
    _empNameCtrl.clear();
    _empEmailCtrl.clear();
    _empCommentCtrl.clear();
    _addingEmp = false;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => StatefulBuilder(
        builder: (context, setLocal) {
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

          void localPick() {
            if (_addingEmp) return;
            FilePicker.platform
                .pickFiles(
                  type: FileType.image,
                  allowMultiple: false,
                  withData: true,
                )
                .then((res) async {
                  try {
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
                    if (bytes == null) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('画像の読み込みに失敗しました')),
                        );
                      }
                      return;
                    }
                    if (context.mounted) {
                      setLocal(() {
                        _empPhotoBytes = bytes;
                        _empPhotoName = f.name;
                      });
                    }
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(SnackBar(content: Text('画像選択エラー: $e')));
                    }
                  }
                });
          }

          return AlertDialog(
            title: const Text('社員を追加'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _addingEmp ? null : localPick,
                    child: CircleAvatar(
                      radius: 40,
                      backgroundImage: (_empPhotoBytes != null)
                          ? MemoryImage(_empPhotoBytes!)
                          : null,
                      child: (_empPhotoBytes == null)
                          ? const Icon(Icons.camera_alt, size: 28)
                          : null,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _empNameCtrl,
                    decoration: const InputDecoration(labelText: '名前（必須）'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _empEmailCtrl,
                    decoration: const InputDecoration(labelText: 'メールアドレス（任意）'),
                    keyboardType: TextInputType.emailAddress,
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _empCommentCtrl,
                    decoration: const InputDecoration(
                      labelText: 'コメント（任意）',
                      hintText: '得意分野や一言メモなど',
                    ),
                    maxLines: 2,
                  ),
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '名前は必須。写真・メール・コメントは任意です',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: _addingEmp ? null : () => Navigator.pop(context),
                child: const Text('キャンセル'),
              ),
              FilledButton(
                onPressed: _addingEmp
                    ? null
                    : () async {
                        final name = _empNameCtrl.text.trim();
                        final email = _empEmailCtrl.text.trim();
                        final comment = _empCommentCtrl.text.trim();
                        if (name.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('名前を入力してください')),
                          );
                          return;
                        }
                        if (email.isNotEmpty && !_validateEmail(email)) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('正しいメールアドレスを入力してください'),
                            ),
                          );
                          return;
                        }

                        setLocal(() => _addingEmp = true);
                        try {
                          final tid = widget.tenantId;
                          final user = FirebaseAuth.instance.currentUser!;
                          final empRef = FirebaseFirestore.instance
                              .collection('tenants')
                              .doc(tid)
                              .collection('employees')
                              .doc();

                          String photoUrl = '';
                          if (_empPhotoBytes != null) {
                            final contentType = _detectContentType(
                              _empPhotoName,
                            );
                            final ext = contentType.split('/').last; // jpeg等
                            final storageRef = FirebaseStorage.instance
                                .ref()
                                .child(
                                  'tenants/$tid/employees/${empRef.id}/photo.$ext',
                                );
                            await storageRef.putData(
                              _empPhotoBytes!,
                              SettableMetadata(contentType: contentType),
                            );
                            photoUrl = await storageRef.getDownloadURL();
                          }

                          await empRef.set({
                            'name': name,
                            'email': email,
                            'photoUrl': photoUrl,
                            'comment': comment,
                            'createdAt': FieldValue.serverTimestamp(),
                            'createdBy': {'uid': user.uid, 'email': user.email},
                          });

                          if (context.mounted) {
                            Navigator.pop(context);
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('社員を追加しました')),
                            );
                          }
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('追加に失敗: $e')),
                            );
                          }
                        } finally {
                          if (context.mounted) {
                            setLocal(() => _addingEmp = false);
                          }
                        }
                      },
                child: _addingEmp
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('追加'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _qrAllLinkCard(String url) {
    final outlinedBtnStyle = OutlinedButton.styleFrom(
      foregroundColor: Colors.black87,
      side: const BorderSide(color: Colors.black87),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    );

    return Container(
      padding: const EdgeInsets.all(14),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '全スタッフQR一覧（共有用URL）',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: Colors.black87,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.link, color: Colors.black54),
              const SizedBox(width: 8),
              Expanded(
                child: SelectableText(
                  url,
                  style: const TextStyle(color: Colors.black87),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton.icon(
                style: outlinedBtnStyle,
                onPressed: () =>
                    launchUrlString(url, mode: LaunchMode.externalApplication),
                icon: const Icon(Icons.open_in_new),
                label: const Text('リンクを開く'),
              ),
              OutlinedButton.icon(
                style: outlinedBtnStyle,
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: url));
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('URLをコピーしました')),
                    );
                  }
                },
                icon: const Icon(Icons.copy),
                label: const Text('URLをコピー'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // === 追加: FABに合わせた動的余白計算 ===
    final mq = MediaQuery.of(context);
    const fabHeight = 44.0; // ボタン高さ
    const fabBottomMargin = 16.0; // 下マージン
    final safeBottom = mq.padding.bottom;
    final gridBottomPadding = fabHeight + fabBottomMargin + safeBottom + 8.0;

    final primaryBtnStyle = FilledButton.styleFrom(
      minimumSize: const Size(0, fabHeight), // 高さ固定
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      padding: const EdgeInsets.symmetric(horizontal: 16),
    );

    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              // 共有リンクカード
              _qrAllLinkCard(_allStaffUrl()),
              const SizedBox(height: 12),

              // 社員一覧
              Expanded(
                child: StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance
                      .collection('tenants')
                      .doc(widget.tenantId)
                      .collection('employees')
                      .orderBy('createdAt', descending: true)
                      .snapshots(),
                  builder: (context, snap) {
                    if (snap.hasError) {
                      return Center(child: Text('読み込みエラー: ${snap.error}'));
                    }
                    if (!snap.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }

                    final docs = snap.data!.docs;
                    if (docs.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              'まだ社員がいません',
                              style: TextStyle(color: Colors.black87),
                            ),
                            const SizedBox(height: 12),
                            OutlinedButton.icon(
                              onPressed: _openAddEmployeeDialog,
                              icon: const Icon(Icons.person_add),
                              label: const Text('最初の社員を追加'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.black87,
                                side: const BorderSide(color: Colors.black87),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 12,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    }

                    final entries = List.generate(docs.length, (i) {
                      final doc = docs[i];
                      final d = docs[i].data() as Map<String, dynamic>;
                      final empId = doc.id;
                      return StaffEntry(
                        index: i + 1,
                        name: (d['name'] ?? '') as String,
                        email: (d['email'] ?? '') as String,
                        photoUrl: (d['photoUrl'] ?? '') as String,
                        comment: (d['comment'] ?? '') as String,
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => StaffDetailScreen(
                                tenantId: widget.tenantId,
                                employeeId: empId,
                              ),
                            ),
                          );
                        },
                      );
                    });

                    // ★ FABと被らない「動的な」下余白
                    return Padding(
                      padding: EdgeInsets.only(bottom: gridBottomPadding),
                      child: StaffGalleryGrid(entries: entries),
                    );
                  },
                ),
              ),
            ],
          ),
        ),

        // 右下フローティング「社員を追加」ボタン
        Positioned(
          right: 16,
          bottom: fabBottomMargin + safeBottom, // セーフエリア考慮
          child: SizedBox(
            height: fabHeight, // 高さを固定
            child: FilledButton.icon(
              style: primaryBtnStyle,
              onPressed: _openAddEmployeeDialog,
              icon: const Icon(Icons.person_add_alt_1),
              label: const Text('社員を追加'),
            ),
          ),
        ),
      ],
    );
  }
}
