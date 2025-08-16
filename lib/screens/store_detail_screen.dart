import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

class StoreDetailScreen extends StatefulWidget {
  const StoreDetailScreen({super.key});

  @override
  State<StoreDetailScreen> createState() => _StoreDetailSScreenState();
}

class _StoreDetailSScreenState extends State<StoreDetailScreen> {
  // ===== 決済タブの状態 =====
  final amountCtrl = TextEditingController(text: '1000');
  String? checkoutUrl;
  String? sessionId;
  String? publicStoreUrl;
  bool loading = false;

  // ===== 共通：選択中の店舗 =====
  String? tenantId;
  String? tenantName;

  // ===== スタッフ追加ダイアログ用の状態 =====
  final _empNameCtrl = TextEditingController();
  final _empEmailCtrl = TextEditingController();
  Uint8List? _empPhotoBytes;
  String? _empPhotoName;
  bool _addingEmp = false;

  bool _argsApplied = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _applyRouteArgsIfAny();
  }

  Future<void> _applyRouteArgsIfAny() async {
    if (_argsApplied) return;
    _argsApplied = true;

    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is Map) {
      final id = args['tenantId'] as String?;
      final nameArg = args['tenantName'] as String?;
      if (id != null) {
        setState(() {
          tenantId = id;
          tenantName = nameArg;
        });
        if (nameArg == null) {
          final doc = await FirebaseFirestore.instance
              .collection('tenants')
              .doc(id)
              .get();
          if (doc.exists) {
            setState(
              () => tenantName = (doc.data()!['name'] as String?) ?? tenantName,
            );
          }
        }
      }
    }

    if (tenantId == null) {
      final user = FirebaseAuth.instance.currentUser!;
      final token = await user.getIdTokenResult(true);
      final idFromClaims = token.claims?['tenantId'] as String?;
      if (idFromClaims != null) {
        setState(() => tenantId = idFromClaims);
        final doc = await FirebaseFirestore.instance
            .collection('tenants')
            .doc(idFromClaims)
            .get();
        if (doc.exists)
          setState(() => tenantName = doc.data()!['name'] as String?);
      }
    }
  }

  // ====== 決済：セッション作成 ======
  Future<void> createSession() async {
    setState(() => loading = true);
    try {
      final callable = FirebaseFunctions.instance.httpsCallable(
        'createCheckoutSession',
      );
      final result = await callable.call({
        'amount': int.parse(amountCtrl.text),
        'memo': 'Walk-in',
      });
      setState(() {
        checkoutUrl = result.data['checkoutUrl'];
        sessionId = result.data['sessionId'];
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('エラー: $e')));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  // ====== スタッフ：追加ダイアログ ======
  Future<void> _pickEmployeePhoto() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
      withData: true, // Web対応：bytesを取得
    );
    if (res != null && res.files.isNotEmpty) {
      setState(() {
        _empPhotoBytes = res.files.single.bytes;
        _empPhotoName = res.files.single.name;
      });
    }
  }

  void _makeStoreQr() {
    if (tenantId == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('店舗が未選択です')));
      return;
    }
    final origin = Uri.base.origin; // 例: https://yourapp.netlify.app
    // ★ Netlifyでも確実に動くようハッシュで固定
    final url = '$origin/#/p?t=$tenantId';
    setState(() => publicStoreUrl = url);
  }

  bool _validateEmail(String v) {
    final s = v.trim();
    if (s.isEmpty) return false;
    // 簡易バリデーション
    return s.contains('@') && s.contains('.');
  }

  Future<void> _openAddEmployeeDialog() async {
    _empNameCtrl.clear();
    _empEmailCtrl.clear();
    _empPhotoBytes = null;
    _empPhotoName = null;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => StatefulBuilder(
        builder: (context, setLocal) {
          Future<void> localPick() async {
            final res = await FilePicker.platform.pickFiles(
              type: FileType.image,
              allowMultiple: false,
              withData: true,
            );
            if (res != null && res.files.isNotEmpty) {
              setLocal(() {
                _empPhotoBytes = res.files.single.bytes;
                _empPhotoName = res.files.single.name;
              });
            }
          }

          return AlertDialog(
            title: const Text('社員を追加'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
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
            actions: [
              TextButton(
                onPressed: _addingEmp ? null : () => Navigator.pop(context),
                child: const Text('キャンセル'),
              ),
              FilledButton(
                onPressed: _addingEmp
                    ? null
                    : () async {
                        // 必須チェック（名前のみ）
                        final name = _empNameCtrl.text.trim();
                        final email = _empEmailCtrl.text.trim();
                        if (name.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('名前を入力してください')),
                          );
                          return;
                        }
                        // メールは任意だが、入っていれば形式チェック
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
                          final tid = tenantId!;
                          final user = FirebaseAuth.instance.currentUser!;
                          final empRef = FirebaseFirestore.instance
                              .collection('tenants')
                              .doc(tid)
                              .collection('employees')
                              .doc(); // 自動ID

                          // 写真は任意：あるときだけアップロード
                          String photoUrl = '';
                          if (_empPhotoBytes != null) {
                            final ext =
                                (_empPhotoName
                                    ?.split('.')
                                    .last
                                    .toLowerCase()) ??
                                'jpg';
                            final contentType =
                                'image/${ext == 'jpg' ? 'jpeg' : ext}';
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

                          // Firestore に保存（メール/写真は空でもOK）
                          await empRef.set({
                            'name': name,
                            'email': email, // 空文字のままでもOK
                            'photoUrl': photoUrl, // 空文字のままでもOK
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
  void dispose() {
    amountCtrl.dispose();
    _empNameCtrl.dispose();
    _empEmailCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final titleText = tenantName ?? '店舗ダッシュボード';

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(titleText),
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.qr_code_2), text: '決済履歴'),
              Tab(icon: Icon(Icons.group), text: 'スタッフ'),
            ],
          ),
          actions: [
            IconButton(
              onPressed: () async {
                await FirebaseAuth.instance.signOut();
                if (!mounted) return;
                Navigator.pushReplacementNamed(context, '/login');
              },
              icon: const Icon(Icons.logout),
              tooltip: 'Sign out',
            ),
          ],
        ),
        body: tenantId == null
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(
                children: [
                  // ===== Tab 1: 決済 =====
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const SizedBox(width: 12),
                            FilledButton.icon(
                              onPressed: loading ? null : _makeStoreQr,
                              icon: const Icon(Icons.qr_code_2),
                              label: const Text('店舗QRコード発行'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        const SizedBox(height: 12),
                        if (publicStoreUrl != null)
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                children: [
                                  QrImageView(data: publicStoreUrl!, size: 240),
                                  const SizedBox(height: 8),
                                  SelectableText(
                                    publicStoreUrl!,
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                          ),

                        const SizedBox(height: 16),
                        const Text('直近セッション'),
                        const SizedBox(height: 8),
                        Expanded(
                          child: StreamBuilder<QuerySnapshot>(
                            stream: FirebaseFirestore.instance
                                .collection('paymentSessions')
                                .where('tenantId', isEqualTo: tenantId)
                                .orderBy('createdAt', descending: true)
                                .limit(50)
                                .snapshots(),
                            builder: (context, snap) {
                              if (snap.hasError) {
                                // よくある原因: ルール or インデックス不足
                                return Center(
                                  child: Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: Text(
                                      '読み込みエラー: ${snap.error}\n'
                                      'Firebaseのインデックス/セキュリティルールを確認してください。',
                                    ),
                                  ),
                                );
                              }

                              if (snap.connectionState ==
                                  ConnectionState.waiting) {
                                return const Center(
                                  child: CircularProgressIndicator(),
                                );
                              }

                              final docs = snap.data?.docs ?? [];
                              if (docs.isEmpty) {
                                return const Center(
                                  child: Text('まだセッションがありません'),
                                );
                              }

                              return ListView.separated(
                                itemCount: docs.length,
                                separatorBuilder: (_, __) =>
                                    const Divider(height: 1),
                                itemBuilder: (_, i) {
                                  final d =
                                      docs[i].data() as Map<String, dynamic>;
                                  final amount = d['amount'];
                                  final status = d['status'];
                                  final url = d['stripeCheckoutUrl'] ?? '';
                                  return ListTile(
                                    leading: const Icon(Icons.receipt_long),
                                    title: Text('¥$amount  •  $status'),
                                    subtitle: Text(
                                      url,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    trailing: Text(
                                      (d['currency'] ?? 'JPY').toString(),
                                    ),
                                  );
                                },
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),

                  // ===== Tab 2: スタッフ =====
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        Align(
                          alignment: Alignment.centerRight,
                          child: FilledButton.icon(
                            onPressed: _openAddEmployeeDialog,
                            icon: const Icon(Icons.person_add_alt_1),
                            label: const Text('社員を追加'),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Expanded(
                          child: StreamBuilder<QuerySnapshot>(
                            stream: FirebaseFirestore.instance
                                .collection('tenants')
                                .doc(tenantId)
                                .collection('employees')
                                .orderBy('createdAt', descending: true)
                                .snapshots(),
                            builder: (context, snap) {
                              if (snap.hasError) {
                                return Center(
                                  child: Text('読み込みエラー: ${snap.error}'),
                                );
                              }
                              if (!snap.hasData) {
                                return const Center(
                                  child: CircularProgressIndicator(),
                                );
                              }
                              final docs = snap.data!.docs;
                              if (docs.isEmpty) {
                                return Center(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Text('まだ社員がいません'),
                                      const SizedBox(height: 8),
                                      OutlinedButton.icon(
                                        onPressed: _openAddEmployeeDialog,
                                        icon: const Icon(Icons.person_add),
                                        label: const Text('最初の社員を追加'),
                                      ),
                                    ],
                                  ),
                                );
                              }

                              return LayoutBuilder(
                                builder: (context, constraints) {
                                  final isWide = constraints.maxWidth >= 720;
                                  if (isWide) {
                                    return GridView.builder(
                                      padding: const EdgeInsets.all(4),
                                      gridDelegate:
                                          const SliverGridDelegateWithFixedCrossAxisCount(
                                            crossAxisCount: 2,
                                            mainAxisSpacing: 12,
                                            crossAxisSpacing: 12,
                                            childAspectRatio: 3.5,
                                          ),
                                      itemCount: docs.length,
                                      itemBuilder: (_, i) {
                                        final d =
                                            docs[i].data()
                                                as Map<String, dynamic>;
                                        return _EmployeeCard(
                                          name: d['name'] ?? '',
                                          email: d['email'] ?? '',
                                          photoUrl: d['photoUrl'] ?? '',
                                        );
                                      },
                                    );
                                  } else {
                                    return ListView.separated(
                                      itemCount: docs.length,
                                      separatorBuilder: (_, __) =>
                                          const SizedBox(height: 12),
                                      itemBuilder: (_, i) {
                                        final d =
                                            docs[i].data()
                                                as Map<String, dynamic>;
                                        return _EmployeeCard(
                                          name: d['name'] ?? '',
                                          email: d['email'] ?? '',
                                          photoUrl: d['photoUrl'] ?? '',
                                        );
                                      },
                                    );
                                  }
                                },
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _EmployeeCard extends StatelessWidget {
  final String name;
  final String email;
  final String photoUrl;

  const _EmployeeCard({
    required this.name,
    required this.email,
    required this.photoUrl,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 6,
      shadowColor: Colors.black26,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {}, // 追加アクションがあればここに
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              CircleAvatar(
                radius: 26,
                backgroundImage: (photoUrl.isNotEmpty)
                    ? NetworkImage(photoUrl)
                    : null,
                child: (photoUrl.isEmpty) ? const Icon(Icons.person) : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(email, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}
