// tabs/staff_tab.dart
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
//import 'package:yourpay/screens/store_detail/card_shell.dart';
import 'package:yourpay/tenant/store_detail/staff_entry.dart'; // StaffEntry

class StoreStaffTab extends StatefulWidget {
  final String tenantId;
  const StoreStaffTab({super.key, required this.tenantId});

  @override
  State<StoreStaffTab> createState() => _StoreStaffTabState();
}

class _StoreStaffTabState extends State<StoreStaffTab> {
  final _empNameCtrl = TextEditingController();
  final _empEmailCtrl = TextEditingController();
  Uint8List? _empPhotoBytes;
  String? _empPhotoName;
  bool _addingEmp = false;

  @override
  void dispose() {
    _empNameCtrl.dispose();
    _empEmailCtrl.dispose();
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
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '名前は必須。写真とメールは任意です',
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
                          if (context.mounted)
                            setLocal(() => _addingEmp = false);
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

  @override
  Widget build(BuildContext context) {
    final primaryBtnStyle = FilledButton.styleFrom(
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    );
    final outlinedBtnStyle = OutlinedButton.styleFrom(
      foregroundColor: Colors.black87,
      side: const BorderSide(color: Colors.black87),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    );

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              style: primaryBtnStyle.copyWith(
                padding: MaterialStateProperty.all(
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
              ),
              onPressed: _openAddEmployeeDialog,
              icon: const Padding(
                padding: EdgeInsets.only(right: 10),
                child: Icon(Icons.person_add_alt_1),
              ),
              label: const Text('社員を追加'),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('tenants')
                  .doc(widget.tenantId)
                  .collection('employees')
                  .orderBy('createdAt', descending: true)
                  .snapshots(),
              builder: (context, snap) {
                if (snap.hasError)
                  return Center(child: Text('読み込みエラー: ${snap.error}'));
                if (!snap.hasData)
                  return const Center(child: CircularProgressIndicator());

                final docs = snap.data!.docs;
                // ここ：docs.isEmpty の分岐を差し替え
                if (docs.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min, // ← 高さを“必要分だけ”
                      children: [
                        const Text(
                          'まだ社員がいません',
                          style: TextStyle(color: Colors.black87),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          style: outlinedBtnStyle,
                          onPressed: _openAddEmployeeDialog,
                          icon: const Icon(Icons.person_add),
                          label: const Text('最初の社員を追加'),
                        ),
                      ],
                    ),
                  );
                }

                final entries = List.generate(docs.length, (i) {
                  final d = docs[i].data() as Map<String, dynamic>;
                  return StaffEntry(
                    index: i + 1,
                    name: (d['name'] ?? '') as String,
                    email: (d['email'] ?? '') as String,
                    photoUrl: (d['photoUrl'] ?? '') as String,
                  );
                });

                return StaffGalleryGrid(entries: entries);
              },
            ),
          ),
        ],
      ),
    );
  }
}
