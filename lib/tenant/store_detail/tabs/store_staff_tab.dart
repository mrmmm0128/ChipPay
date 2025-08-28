// lib/tenant/store_detail/tabs/staff_tab.dart
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

  // 取り込み用（グローバル/他店舗）
  String? _prefilledPhotoUrlFromGlobal;
  Uint8List? _empPhotoBytes;
  String? _empPhotoName;

  bool _addingEmp = false;

  // 公開ページのベースURL（末尾スラなし）
  String get _publicBase {
    final u = Uri.base; // 例: http://localhost:5173/#/qr-all?t=...
    final isHttp =
        (u.scheme == 'http' || u.scheme == 'https') && u.host.isNotEmpty;
    if (isHttp) {
      return '${u.scheme}://${u.host}${u.hasPort ? ':${u.port}' : ''}';
    }
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

  // ---------- 便利関数 ----------
  String _normalizeEmail(String v) => v.trim().toLowerCase();

  bool _validateEmail(String v) {
    final s = v.trim();
    if (s.isEmpty) return false;
    return s.contains('@') && s.contains('.');
  }

  Future<Map<String, dynamic>?> _lookupGlobalStaff(String email) async {
    final id = _normalizeEmail(email);
    if (id.isEmpty) return null;
    final doc = await FirebaseFirestore.instance
        .collection('staff')
        .doc(id)
        .get();
    if (!doc.exists) return null;
    final data = (doc.data() ?? {})..['id'] = doc.id;
    return data.cast<String, dynamic>();
  }

  Future<QueryDocumentSnapshot<Map<String, dynamic>>?> _findTenantDupByEmail(
    String tenantId,
    String email,
  ) async {
    final q = await FirebaseFirestore.instance
        .collection('tenants')
        .doc(tenantId)
        .collection('employees')
        .where('email', isEqualTo: _normalizeEmail(email))
        .limit(1)
        .get();
    return q.docs.isEmpty ? null : q.docs.first;
  }

  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>>
  _loadMyTenants() async {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    final qs = await FirebaseFirestore.instance
        .collection('tenants')
        .where('members', arrayContains: uid)
        .get();
    return qs.docs;
  }

  Future<bool?> _confirmDuplicateDialog({
    required BuildContext context,
    required Map<String, dynamic> existing,
  }) {
    final name = (existing['name'] ?? '') as String? ?? '';
    final email = (existing['email'] ?? '') as String? ?? '';
    final photoUrl = (existing['photoUrl'] ?? '') as String? ?? '';
    return showDialog<bool>(
      context: context,
      builder: (_) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: Theme.of(context).colorScheme.copyWith(
            primary: Colors.black87,
            onPrimary: Colors.white,
            surfaceTint: Colors.transparent,
          ),
        ),
        child: AlertDialog(
          backgroundColor: const Color(0xFFF5F5F5),
          surfaceTintColor: Colors.transparent,
          titleTextStyle: const TextStyle(
            color: Colors.black87,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
          contentTextStyle: const TextStyle(color: Colors.black87),
          title: const Text('同一人物の可能性があります'),
          content: Row(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundImage: photoUrl.isNotEmpty
                    ? NetworkImage(photoUrl)
                    : null,
                child: photoUrl.isEmpty ? const Icon(Icons.person) : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name.isNotEmpty ? name : 'スタッフ',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(email, style: const TextStyle(color: Colors.black54)),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              style: TextButton.styleFrom(foregroundColor: Colors.black87),
              child: const Text('別人として追加'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.black,
                foregroundColor: Colors.white,
              ),
              child: const Text('同一人物（既存を見る）'),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- ダイアログ：スタッフ追加（タブ付き） ----------
  Future<void> _openAddEmployeeDialog() async {
    // 事前リセット
    _empPhotoBytes = null;
    _empPhotoName = null;
    _prefilledPhotoUrlFromGlobal = null;
    _empNameCtrl.clear();
    _empEmailCtrl.clear();
    _empCommentCtrl.clear();
    _addingEmp = false;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _AddStaffDialog(
        currentTenantId: widget.tenantId,
        nameCtrl: _empNameCtrl,
        emailCtrl: _empEmailCtrl,
        commentCtrl: _empCommentCtrl,
        addingEmp: _addingEmp,
        prefilledPhotoUrlFromGlobal: _prefilledPhotoUrlFromGlobal,
        empPhotoBytes: _empPhotoBytes,
        empPhotoName: _empPhotoName,
        onLocalStateChanged: (adding, bytes, name, prefilledUrl) {
          setState(() {
            _addingEmp = adding;
            _empPhotoBytes = bytes;
            _empPhotoName = name;
            _prefilledPhotoUrlFromGlobal = prefilledUrl;
          });
        },
        // 検索系/重複チェックのハンドラ
        normalizeEmail: _normalizeEmail,
        validateEmail: _validateEmail,
        lookupGlobalStaff: _lookupGlobalStaff,
        findTenantDupByEmail: _findTenantDupByEmail,
        confirmDuplicateDialog: _confirmDuplicateDialog,
        loadMyTenants: _loadMyTenants,
      ),
    );
  }

  // ---------- 一覧上部の共有リンクカード ----------
  Widget _qrAllLinkCard(String url) {
    final outlinedBtnStyle = OutlinedButton.styleFrom(
      foregroundColor: Colors.black87,
      side: const BorderSide(color: Colors.black87),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    );
    return Container(
      padding: const EdgeInsets.all(7),
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
      child: Center(
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
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  style: outlinedBtnStyle,
                  onPressed: () => launchUrlString(
                    url,
                    mode: LaunchMode.externalApplication,
                  ),
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
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // FABに合わせた動的余白
    final mq = MediaQuery.of(context);
    const fabHeight = 44.0;
    const fabBottomMargin = 16.0;
    final safeBottom = mq.padding.bottom;
    final gridBottomPadding = fabHeight + fabBottomMargin + safeBottom + 8.0;

    final primaryBtnStyle = FilledButton.styleFrom(
      minimumSize: const Size(0, fabHeight),
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
              _qrAllLinkCard(_allStaffUrl()),
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
        Positioned(
          right: 16,
          bottom: fabBottomMargin + safeBottom,
          child: SizedBox(
            height: fabHeight,
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

/// ===============================================================
/// 追加・変更ダイアログ（タブ付き）
///  - タブ1: 新規作成 / グローバル（staff/{email}）取り込み
///  - タブ2: 他店舗から取り込み（自分がメンバーのテナント）
///    → 店舗選択は**スクロール可能な専用ダイアログ**で選択
/// ===============================================================
class _AddStaffDialog extends StatefulWidget {
  final String currentTenantId;

  final TextEditingController nameCtrl;
  final TextEditingController emailCtrl;
  final TextEditingController commentCtrl;

  bool addingEmp;
  Uint8List? empPhotoBytes;
  String? empPhotoName;
  String? prefilledPhotoUrlFromGlobal;

  // 状態反映
  final void Function(
    bool adding,
    Uint8List? bytes,
    String? name,
    String? prefilledUrl,
  )
  onLocalStateChanged;

  // ハンドラ（親から注入）
  final String Function(String value) normalizeEmail;
  final bool Function(String value) validateEmail;
  final Future<Map<String, dynamic>?> Function(String email) lookupGlobalStaff;
  final Future<QueryDocumentSnapshot<Map<String, dynamic>>?> Function(
    String tenantId,
    String email,
  )
  findTenantDupByEmail;
  final Future<bool?> Function({
    required BuildContext context,
    required Map<String, dynamic> existing,
  })
  confirmDuplicateDialog;
  final Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>> Function()
  loadMyTenants;

  _AddStaffDialog({
    required this.currentTenantId,
    required this.nameCtrl,
    required this.emailCtrl,
    required this.commentCtrl,
    required this.addingEmp,
    required this.empPhotoBytes,
    required this.empPhotoName,
    required this.prefilledPhotoUrlFromGlobal,
    required this.onLocalStateChanged,
    required this.normalizeEmail,
    required this.validateEmail,
    required this.lookupGlobalStaff,
    required this.findTenantDupByEmail,
    required this.confirmDuplicateDialog,
    required this.loadMyTenants,
  });

  @override
  State<_AddStaffDialog> createState() => _AddStaffDialogState();
}

class _AddStaffDialogState extends State<_AddStaffDialog>
    with SingleTickerProviderStateMixin {
  late TabController _tab;

  // タブ2（他店舗から取り込み）用
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _myTenants = [];
  String? _selectedTenantId; // 現在の店舗以外
  String _otherSearch = ''; // 名前/メールの部分一致（ローカルフィルタ）
  final _tenantSearchCtrl = TextEditingController(); // 店舗ピッカー内の検索

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
    _prepareMyTenants();
  }

  @override
  void dispose() {
    _tab.dispose();
    _tenantSearchCtrl.dispose();
    super.dispose();
  }

  Future<void> _prepareMyTenants() async {
    final tenants = await widget.loadMyTenants();
    setState(() {
      _myTenants = tenants
          .where((d) => d.id != widget.currentTenantId)
          .toList();
      _selectedTenantId = _myTenants.isEmpty ? null : _myTenants.first.id;
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

  Future<void> _pickPhoto() async {
    if (widget.addingEmp) return;
    final res = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
      withData: true,
    );
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
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('画像の読み込みに失敗しました')));
        }
        return;
      }
      widget.onLocalStateChanged(false, bytes, f.name, null); // 手元画像を優先
      setState(() {});
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('画像選択エラー: $e')));
      }
    }
  }

  // ============= タブ1：新規/グローバル取り込み =============
  Future<void> _searchGlobalByEmail() async {
    final email = widget.normalizeEmail(widget.emailCtrl.text);
    if (email.isEmpty || !widget.validateEmail(email)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('検索には正しいメールアドレスが必要です')));
      return;
    }
    final data = await widget.lookupGlobalStaff(email);
    if (data == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('一致するスタッフは見つかりませんでした')));
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: Theme.of(context).colorScheme.copyWith(
            primary: Colors.black87,
            onPrimary: Colors.white,
            surfaceTint: Colors.transparent,
          ),
        ),
        child: AlertDialog(
          backgroundColor: const Color(0xFFF5F5F5),
          surfaceTintColor: Colors.transparent,
          titleTextStyle: const TextStyle(
            color: Colors.black87,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
          contentTextStyle: const TextStyle(color: Colors.black87),
          title: const Text('プロフィールを取り込みますか？'),
          content: Row(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundImage: (data['photoUrl'] ?? '').toString().isNotEmpty
                    ? NetworkImage((data['photoUrl'] as String))
                    : null,
                child: ((data['photoUrl'] ?? '') as String).isEmpty
                    ? const Icon(Icons.person)
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      (data['name'] ?? '') as String? ?? '',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      (data['email'] ?? '') as String? ?? '',
                      style: const TextStyle(color: Colors.black54),
                    ),
                    if ((data['comment'] ?? '').toString().isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        (data['comment'] as String),
                        style: const TextStyle(color: Colors.black87),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              style: TextButton.styleFrom(foregroundColor: Colors.black87),
              child: const Text('閉じる'),
            ),
            FilledButton(
              onPressed: () {
                // フィールドに反映（写真はURL保持）
                widget.nameCtrl.text =
                    (data['name'] as String?) ?? widget.nameCtrl.text;
                widget.commentCtrl.text =
                    (data['comment'] as String?) ?? widget.commentCtrl.text;
                widget.onLocalStateChanged(
                  false,
                  null,
                  null,
                  (data['photoUrl'] as String?) ?? '',
                ); // URL優先に切替
                Navigator.pop(context);
                setState(() {});
              },
              style: FilledButton.styleFrom(
                backgroundColor: Colors.black,
                foregroundColor: Colors.white,
              ),
              child: const Text('取り込む'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _submitCreate() async {
    if (widget.addingEmp) return;
    final name = widget.nameCtrl.text.trim();
    final email = widget.normalizeEmail(widget.emailCtrl.text);
    final comment = widget.commentCtrl.text.trim();

    if (name.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('名前を入力してください')));
      return;
    }
    if (email.isNotEmpty && !widget.validateEmail(email)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('正しいメールアドレスを入力してください')));
      return;
    }

    // 現在の店舗で同じメールがいるか
    if (email.isNotEmpty) {
      final dup = await widget.findTenantDupByEmail(
        widget.currentTenantId,
        email,
      );
      if (dup != null) {
        final same = await widget.confirmDuplicateDialog(
          context: context,
          existing: {
            'name': dup.data()['name'],
            'email': dup.data()['email'],
            'photoUrl': dup.data()['photoUrl'],
          },
        );
        if (same == true) {
          if (context.mounted) {
            Navigator.pop(context); // ダイアログを閉じる
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => StaffDetailScreen(
                  tenantId: widget.currentTenantId,
                  employeeId: dup.id,
                ),
              ),
            );
          }
          return;
        }
        // 別人として続行
      }
    }

    // 追加
    _createEmployee(
      tenantId: widget.currentTenantId,
      name: name,
      email: email,
      comment: comment,
    );
  }

  Future<void> _createEmployee({
    required String tenantId,
    required String name,
    required String email,
    required String comment,
  }) async {
    widget.onLocalStateChanged(
      true,
      widget.empPhotoBytes,
      widget.empPhotoName,
      widget.prefilledPhotoUrlFromGlobal,
    );
    try {
      final user = FirebaseAuth.instance.currentUser!;
      final empRef = FirebaseFirestore.instance
          .collection('tenants')
          .doc(tenantId)
          .collection('employees')
          .doc();

      // 写真アップロード
      String photoUrl = '';
      if (widget.empPhotoBytes != null) {
        final contentType = _detectContentType(widget.empPhotoName);
        final ext = contentType.split('/').last;
        final storageRef = FirebaseStorage.instance.ref().child(
          'tenants/$tenantId/employees/${empRef.id}/photo.$ext',
        );
        await storageRef.putData(
          widget.empPhotoBytes!,
          SettableMetadata(contentType: contentType),
        );
        photoUrl = await storageRef.getDownloadURL();
      } else if ((widget.prefilledPhotoUrlFromGlobal ?? '').isNotEmpty) {
        photoUrl = widget.prefilledPhotoUrlFromGlobal!;
      }

      await empRef.set({
        'name': name,
        'email': email,
        'photoUrl': photoUrl,
        'comment': comment,
        'createdAt': FieldValue.serverTimestamp(),
        'createdBy': {'uid': user.uid, 'email': user.email},
      });

      // グローバル staff/{email} を軽く upsert
      if (email.isNotEmpty) {
        await FirebaseFirestore.instance.collection('staff').doc(email).set({
          'email': email,
          if (name.isNotEmpty) 'name': name,
          if (photoUrl.isNotEmpty) 'photoUrl': photoUrl,
          if (comment.isNotEmpty) 'comment': comment,
          'tenants': FieldValue.arrayUnion([tenantId]),
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }

      if (context.mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('社員を追加しました')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('追加に失敗: $e')));
      }
    } finally {
      widget.onLocalStateChanged(
        false,
        widget.empPhotoBytes,
        widget.empPhotoName,
        widget.prefilledPhotoUrlFromGlobal,
      );
    }
  }

  // ============= タブ2：他店舗から取り込み =============

  String _selectedTenantName() {
    if (_selectedTenantId == null) return '店舗を選択';
    final idx = _myTenants.indexWhere((d) => d.id == _selectedTenantId);
    if (idx < 0) return '店舗を選択';
    final name = (_myTenants[idx].data()['name'] ?? '(no name)').toString();
    return name.isEmpty ? '(no name)' : name;
  }

  Future<void> _openTenantPickerDialog() async {
    // ダイアログ内検索を初期化
    _tenantSearchCtrl.text = '';
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        String localQuery = '';
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            // フィルタ済み一覧
            final list = _myTenants.where((d) {
              if (localQuery.isEmpty) return true;
              final name = (d.data()['name'] ?? '').toString().toLowerCase();
              return name.contains(localQuery);
            }).toList();

            return Theme(
              data: Theme.of(ctx).copyWith(
                colorScheme: Theme.of(ctx).colorScheme.copyWith(
                  primary: Colors.black87,
                  onPrimary: Colors.white,
                  surfaceTint: Colors.transparent,
                ),
              ),
              child: AlertDialog(
                backgroundColor: const Color(0xFFF5F5F5),
                surfaceTintColor: Colors.transparent,
                title: const Text(
                  '店舗を選択',
                  style: TextStyle(
                    color: Colors.black87,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                content: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: SizedBox(
                    height: 420, // ← スクロール領域の高さ
                    child: Column(
                      children: [
                        TextField(
                          controller: _tenantSearchCtrl,
                          decoration: InputDecoration(
                            hintText: '店舗名で検索',
                            isDense: true,
                            filled: true,
                            fillColor: Colors.white,
                            prefixIcon: const Icon(Icons.search),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide.none,
                            ),
                          ),
                          onChanged: (v) => setLocal(
                            () => localQuery = v.trim().toLowerCase(),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          child: Scrollbar(
                            thumbVisibility: true,
                            child: ListView.separated(
                              itemCount: list.length,
                              separatorBuilder: (_, __) =>
                                  const Divider(height: 1),
                              itemBuilder: (_, i) {
                                final t = list[i];
                                final name = (t.data()['name'] ?? '(no name)')
                                    .toString();
                                final selected = t.id == _selectedTenantId;
                                return ListTile(
                                  dense: true,
                                  title: Text(
                                    name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  trailing: selected
                                      ? const Icon(
                                          Icons.check,
                                          color: Colors.black87,
                                        )
                                      : null,
                                  onTap: () {
                                    setState(() => _selectedTenantId = t.id);
                                    Navigator.pop(ctx);
                                  },
                                );
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.black87,
                    ),
                    child: const Text('閉じる'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _otherTenantsTab() {
    if (_myTenants.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Text(
          'あなたがメンバーの他店舗が見つかりませんでした',
          style: TextStyle(color: Colors.black87),
        ),
      );
    }

    // 選択済み店舗のストリーム（未選択時はプレースホルダ表示）
    final selectedId = _selectedTenantId;
    final employeesStream = (selectedId == null)
        ? null
        : FirebaseFirestore.instance
              .collection('tenants')
              .doc(selectedId)
              .collection('employees')
              .orderBy('createdAt', descending: true)
              .snapshots();

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 店舗選択 + 検索
        Row(
          children: [
            Expanded(
              child: GestureDetector(
                onTap: _openTenantPickerDialog,
                child: InputDecorator(
                  decoration: InputDecoration(
                    labelText: '店舗を選択',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _selectedTenantName(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const Icon(Icons.arrow_drop_down),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                decoration: InputDecoration(
                  labelText: '名前/メールで絞り込み（ローカル）',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  isDense: true,
                ),
                onChanged: (v) =>
                    setState(() => _otherSearch = v.trim().toLowerCase()),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),

        // リスト（店舗未選択なら案内）
        if (employeesStream == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Text(
              'まず「店舗を選択」をタップして候補を選んでください',
              style: TextStyle(color: Colors.black87),
            ),
          )
        else
          Flexible(
            child: StreamBuilder<QuerySnapshot>(
              stream: employeesStream,
              builder: (context, snap) {
                if (snap.hasError) {
                  return Center(child: Text('読み込みエラー: ${snap.error}'));
                }
                if (!snap.hasData) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: CircularProgressIndicator(),
                  );
                }
                final docs = snap.data!.docs;
                var items = docs
                    .map((d) => d.data() as Map<String, dynamic>)
                    .toList();
                if (_otherSearch.isNotEmpty) {
                  items = items.where((m) {
                    final name = (m['name'] ?? '').toString().toLowerCase();
                    final email = (m['email'] ?? '').toString().toLowerCase();
                    return name.contains(_otherSearch) ||
                        email.contains(_otherSearch);
                  }).toList();
                }
                if (items.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Text('該当スタッフがいません'),
                  );
                }

                return ListView.separated(
                  shrinkWrap: true,
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final m = items[i];
                    final name = (m['name'] ?? '') as String? ?? 'スタッフ';
                    final email = (m['email'] ?? '') as String? ?? '';
                    final photoUrl = (m['photoUrl'] ?? '') as String? ?? '';
                    final comment = (m['comment'] ?? '') as String? ?? '';

                    return Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0x11000000)),
                      ),
                      padding: const EdgeInsets.all(10),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 22,
                            backgroundImage: photoUrl.isNotEmpty
                                ? NetworkImage(photoUrl)
                                : null,
                            child: photoUrl.isEmpty
                                ? const Icon(Icons.person)
                                : null,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    color: Colors.black87,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                if (email.isNotEmpty)
                                  Text(
                                    email,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.black54,
                                    ),
                                  ),
                                if (comment.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    comment,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.black87,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton.tonalIcon(
                            onPressed: () {
                              // 取り込み（タブ1のフォームに反映）
                              widget.nameCtrl.text = name;
                              widget.emailCtrl.text = email;
                              widget.commentCtrl.text = comment;
                              widget.onLocalStateChanged(
                                false,
                                null,
                                null,
                                photoUrl,
                              );
                              // タブ1に切り替え
                              _tab.animateTo(0);
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('フォームに取り込みました（取り込み先は現在の店舗）'),
                                ),
                              );
                              setState(() {});
                            },
                            icon: const Icon(Icons.download),
                            label: const Text('取り込む'),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
        const SizedBox(height: 8),
        const Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '※ 取り込み先は「現在の店舗」です。保存ボタンで確定します。',
            style: TextStyle(fontSize: 12, color: Colors.black54),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final photoProvider = (widget.empPhotoBytes != null)
        ? MemoryImage(widget.empPhotoBytes!)
        : ((widget.prefilledPhotoUrlFromGlobal ?? '').isNotEmpty
                  ? NetworkImage(widget.prefilledPhotoUrlFromGlobal!)
                  : null)
              as ImageProvider<Object>?;

    return Theme(
      data: Theme.of(context).copyWith(
        colorScheme: Theme.of(context).colorScheme.copyWith(
          primary: Colors.black87,
          onPrimary: Colors.white,
          surfaceTint: Colors.transparent,
        ),
        textSelectionTheme: const TextSelectionThemeData(
          cursorColor: Colors.black87,
          selectionColor: Color(0x33000000),
          selectionHandleColor: Colors.black87,
        ),
      ),
      child: AlertDialog(
        backgroundColor: const Color(0xFFF5F5F5),
        surfaceTintColor: Colors.transparent,
        titlePadding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
        contentPadding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '社員を追加',
              style: TextStyle(
                color: Colors.black87,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              child: TabBar(
                controller: _tab,
                labelColor: Colors.black87,
                unselectedLabelColor: Colors.black54,
                indicator: BoxDecoration(
                  color: const Color(0xFFEAEAEA),
                  borderRadius: BorderRadius.circular(12),
                ),
                tabs: const [
                  Tab(text: '新規 / グローバル'),
                  Tab(text: '他店舗から取り込み'),
                ],
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 640,
          child: DefaultTextStyle.merge(
            style: const TextStyle(color: Colors.black87),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(height: 16, child: Container()),
                SizedBox(
                  height: 420,
                  child: TabBarView(
                    controller: _tab,
                    children: [
                      // タブ1：新規 / グローバル取り込み
                      SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: widget.addingEmp ? null : _pickPhoto,
                              child: CircleAvatar(
                                radius: 40,
                                backgroundImage: photoProvider,
                                child: photoProvider == null
                                    ? const Icon(Icons.camera_alt, size: 28)
                                    : null,
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: widget.nameCtrl,
                              decoration: _inputDeco('名前（必須）'),
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              controller: widget.emailCtrl,
                              keyboardType: TextInputType.emailAddress,
                              decoration: _inputDeco(
                                'メールアドレス（任意・検索可）',
                                suffix: IconButton(
                                  tooltip: 'メールで検索（グローバル）',
                                  icon: const Icon(Icons.search),
                                  onPressed: widget.addingEmp
                                      ? null
                                      : _searchGlobalByEmail,
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              controller: widget.commentCtrl,
                              maxLines: 2,
                              decoration: _inputDeco(
                                'コメント（任意）',
                                hint: '得意分野や一言メモなど',
                              ),
                            ),
                            const SizedBox(height: 6),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                '名前は必須。写真・メール・コメントは任意です。\nメール検索で「staff/{email}」から取り込めます。',
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: Colors.black54),
                              ),
                            ),
                          ],
                        ),
                      ),

                      // タブ2：他店舗から取り込み
                      _otherTenantsTab(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        actions: [
          TextButton(
            onPressed: widget.addingEmp ? null : () => Navigator.pop(context),
            style: TextButton.styleFrom(foregroundColor: Colors.black87),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: widget.addingEmp ? null : _submitCreate,
            style: FilledButton.styleFrom(
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
            ),
            child: widget.addingEmp
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('追加'),
          ),
        ],
      ),
    );
  }

  InputDecoration _inputDeco(String label, {String? hint, Widget? suffix}) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Colors.black26),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Colors.black87, width: 1.2),
      ),
      suffixIcon: suffix,
    );
  }
}
