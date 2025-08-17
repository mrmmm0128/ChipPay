import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher_string.dart';

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

  final _functions = FirebaseFunctions.instanceFor(region: 'us-central1');

  Future<void> _openOnboarding() async {
    if (tenantId == null) return;
    final res = await _functions
        .httpsCallable('createAccountOnboardingLink')
        .call({'tenantId': tenantId});
    final url = (res.data as Map)['url'] as String;
    await launchUrlString(url, mode: LaunchMode.externalApplication);
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
  // Future<void> _pickEmployeePhoto() async {
  //   final res = await FilePicker.platform.pickFiles(
  //     type: FileType.image,
  //     allowMultiple: false,
  //     withData: true, // Web対応：bytesを取得
  //   );
  //   if (res != null && res.files.isNotEmpty) {
  //     setState(() {
  //       _empPhotoBytes = res.files.single.bytes;
  //       _empPhotoName = res.files.single.name;
  //     });
  //   }
  // }

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
    // 前回選択のクリア
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
          // ★ ヘルパー：content-type 判定
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

          // ★ ピッカーは同期に起動（awaitしない）
          void localPick() {
            if (_addingEmp) return;
            FilePicker.platform
                .pickFiles(
                  type: FileType.image,
                  allowMultiple: false,
                  withData: true, // Web でも bytes を取得
                )
                .then((res) async {
                  try {
                    if (res == null || res.files.isEmpty) return;
                    final f = res.files.single;

                    Uint8List? bytes = f.bytes;
                    // 一部環境向けフォールバック（readStream）
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
                  // ★ タップ取りこぼし防止
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
                            final contentType = _detectContentType(
                              _empPhotoName,
                            );
                            final ext = contentType.split('/').last; // jpeg 等
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
                        // ※ tenantId が null じゃない前提で呼ばれる位置に置いてください
                        StreamBuilder<DocumentSnapshot>(
                          stream: FirebaseFirestore.instance
                              .collection('tenants')
                              .doc(tenantId)
                              .snapshots(),
                          builder: (context, snap) {
                            if (snap.connectionState ==
                                ConnectionState.waiting) {
                              return const Padding(
                                padding: EdgeInsets.symmetric(vertical: 12),
                                child: LinearProgressIndicator(minHeight: 2),
                              );
                            }
                            final data =
                                snap.data?.data() as Map<String, dynamic>?;

                            final hasAccount =
                                ((data?['stripeAccountId'] as String?)
                                    ?.isNotEmpty ??
                                false);
                            final connected =
                                (data?['connect']?['charges_enabled']
                                    as bool?) ??
                                false;

                            // 未接続時は既存のQRを消しておく（任意）
                            if (!connected && publicStoreUrl != null) {
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                if (mounted)
                                  setState(() => publicStoreUrl = null);
                              });
                            }

                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // ① 接続してない場合は注意カード
                                if (!connected)
                                  Card(
                                    color: Colors.amber.withOpacity(0.15),
                                    child: ListTile(
                                      leading: const Icon(Icons.info_outline),
                                      title: Text(
                                        hasAccount
                                            ? 'Stripeオンボーディング未完了のため、QR発行はできません。'
                                            : 'Stripe未接続のため、QR発行はできません。',
                                      ),
                                      subtitle: const Text(
                                        '決済を受け付けるにはStripeに接続し、オンボーディングを完了してください。',
                                      ),
                                      trailing: FilledButton(
                                        onPressed: _openOnboarding,
                                        child: Text(
                                          hasAccount ? '続きから再開' : 'Stripeに接続',
                                        ),
                                      ),
                                    ),
                                  ),

                                // ② QR発行ボタン（接続済みでないと押せない）
                                Row(
                                  children: [
                                    Expanded(
                                      child: FilledButton.icon(
                                        onPressed: (connected && !loading)
                                            ? _makeStoreQr
                                            : null,
                                        icon: const Icon(Icons.qr_code_2),
                                        label: const Text('店舗QRコード発行'),
                                      ),
                                    ),
                                  ],
                                ),

                                const SizedBox(height: 12),

                                // ③ 接続済み & URLが生成されたらQRを表示
                                if (connected && publicStoreUrl != null)
                                  Card(
                                    child: Padding(
                                      padding: const EdgeInsets.all(16),
                                      child: Column(
                                        children: [
                                          QrImageView(
                                            data: publicStoreUrl!,
                                            size: 240,
                                          ),
                                          const SizedBox(height: 8),
                                          SelectableText(
                                            publicStoreUrl!,
                                            style: const TextStyle(
                                              fontSize: 12,
                                            ),
                                          ),
                                          const SizedBox(height: 8),
                                          Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              OutlinedButton.icon(
                                                icon: const Icon(
                                                  Icons.open_in_new,
                                                ),
                                                label: const Text('開く'),
                                                onPressed: () =>
                                                    launchUrlString(
                                                      publicStoreUrl!,
                                                      mode: LaunchMode
                                                          .externalApplication,
                                                    ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                              ],
                            );
                          },
                        ),

                        const SizedBox(height: 12),

                        const SizedBox(height: 16),
                        const Text('直近セッション'),
                        const SizedBox(height: 8),
                        Expanded(
                          child: StreamBuilder<QuerySnapshot>(
                            stream: FirebaseFirestore.instance
                                .collection('tenants')
                                .doc(
                                  tenantId,
                                ) // ← ここがポイント：テナント配下の tips サブコレクション
                                .collection('tips')
                                .orderBy('createdAt', descending: true)
                                .limit(50)
                                .snapshots(),
                            builder: (context, snap) {
                              if (snap.hasError) {
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
                                  child: Text('まだチップ履歴がありません'),
                                );
                              }

                              String _symbol(String code) {
                                switch ((code).toUpperCase()) {
                                  case 'JPY':
                                    return '¥';
                                  case 'USD':
                                    return '\$';
                                  case 'EUR':
                                    return '€';
                                  default:
                                    return ''; // 記号が不明なら後ろに通貨コードを出す
                                }
                              }

                              return ListView.separated(
                                itemCount: docs.length,
                                separatorBuilder: (_, __) =>
                                    const Divider(height: 1),
                                itemBuilder: (_, i) {
                                  final d =
                                      docs[i].data() as Map<String, dynamic>;

                                  final recipient = (d['recipient'] as Map?)
                                      ?.cast<String, dynamic>();
                                  final isEmployee =
                                      (recipient?['type'] == 'employee') ||
                                      (d['employeeId'] != null);
                                  final employeeName =
                                      recipient?['employeeName'] ??
                                      d['employeeName'] ??
                                      'スタッフ';
                                  final storeName =
                                      recipient?['storeName'] ??
                                      d['storeName'] ??
                                      '店舗';

                                  final targetLabel = isEmployee
                                      ? 'スタッフ: $employeeName'
                                      : '店舗: $storeName';

                                  final amountNum = (d['amount'] as num?) ?? 0;
                                  final currency =
                                      (d['currency'] as String?)
                                          ?.toUpperCase() ??
                                      'JPY';
                                  final symbol = _symbol(currency);
                                  final amountText = symbol.isNotEmpty
                                      ? '$symbol${amountNum.toInt()}'
                                      : '${amountNum.toInt()} $currency';

                                  final status =
                                      (d['status'] as String?) ?? 'unknown';
                                  final ts = d['createdAt'];
                                  String when = '';
                                  if (ts is Timestamp) {
                                    final dt = ts.toDate().toLocal();
                                    // 見やすい簡易フォーマット（intl なし）
                                    when =
                                        '${dt.year}/${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')} '
                                        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
                                  }

                                  return ListTile(
                                    leading: CircleAvatar(
                                      child: Icon(
                                        isEmployee ? Icons.person : Icons.store,
                                      ),
                                    ),
                                    title: Text(
                                      targetLabel,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    subtitle: Text(
                                      [
                                        'ステータス: $status',
                                        if (when.isNotEmpty) when,
                                      ].join('  •  '),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    trailing: Text(
                                      amountText,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 16,
                                      ),
                                    ),
                                    // 必要なら onTap で URL を開く（pending の時など）
                                    // onTap: () {
                                    //   final url = d['stripeCheckoutUrl'] as String?;
                                    //   if (url != null && url.isNotEmpty) {
                                    //     launchUrlString(url, mode: LaunchMode.externalApplication);
                                    //   }
                                    // },
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
