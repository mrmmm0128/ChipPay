// tenant_drawer.dart
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

// 使い方：Scaffold(drawer: TenantDrawer(...))

class TenantDrawer extends StatefulWidget {
  final String? currentTenantId;
  final String? currentTenantName;

  /// 従来のコールバック（互換）
  final void Function(String tenantId, String? tenantName) onChanged;

  /// 親側の「新規作成」処理を呼び出すためのコールバック
  final VoidCallback onCreateTenant;

  /// 拡張：ownerUid / invited も渡す
  final void Function(
    String tenantId,
    String? tenantName,
    String ownerUid,
    bool invited,
  )?
  onChangedEx;

  const TenantDrawer({
    super.key,
    required this.onChanged,
    required this.onCreateTenant,
    this.onChangedEx,
    this.currentTenantId,
    this.currentTenantName,
  });

  @override
  State<TenantDrawer> createState() => _TenantDrawerState();
}

class _TenantDrawerState extends State<TenantDrawer> {
  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  // ------- ストリーム合成（自分 + 招待） -------
  final _rows = <String, _TenantRow>{}; // key = "$ownerUid/$tenantId"
  final _ctrl = StreamController<List<_TenantRow>>.broadcast();
  Stream<List<_TenantRow>> get _stream => _ctrl.stream;

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _ownedSub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _invitedIndexSub;
  final _invitedDocSubs =
      <String, StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>>{};

  String _keyOf(String ownerUid, String tenantId) => '$ownerUid/$tenantId';

  String? _selectedKey; // "$ownerUid/$tenantId" を保持
  String? _selectedId; // 互換用

  @override
  void initState() {
    super.initState();
    _selectedId = widget.currentTenantId;
    _wireStreams();
  }

  @override
  void didUpdateWidget(covariant TenantDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentTenantId != widget.currentTenantId) {
      _selectedId = widget.currentTenantId;
      // _selectedKey は一覧が来たタイミングで同定
    }
  }

  void _emit() {
    final list = _rows.values.toList()
      ..sort(
        (a, b) => (a.data['name'] ?? '').toString().toLowerCase().compareTo(
          (b.data['name'] ?? '').toString().toLowerCase(),
        ),
      );
    _ctrl.add(list);
  }

  void _wireStreams() {
    final uid = _uid;
    if (uid == null) return;

    // (1) 自分のテナント群
    _ownedSub = FirebaseFirestore.instance.collection(uid).snapshots().listen((
      qs,
    ) {
      _rows.removeWhere((k, _) => k.startsWith('$uid/'));
      for (final d in qs.docs) {
        final key = _keyOf(uid, d.id);
        _rows[key] = _TenantRow(
          ownerUid: uid,
          tenantId: d.id,
          data: d.data(),
          invited: false,
        );
      }
      _emit();
    });

    // (2) 招待インデックス /<uid>/invited → 各オーナー配下の実体を購読
    final invitedRef = FirebaseFirestore.instance
        .collection(uid)
        .doc('invited');
    _invitedIndexSub = invitedRef.snapshots().listen((doc) {
      final map = (doc.data()?['tenants'] as Map<String, dynamic>?) ?? {};
      final should = <String>{};

      map.forEach((tenantId, v) {
        final ownerUid = (v is Map ? v['ownerUid'] : null)?.toString() ?? '';
        if (ownerUid.isEmpty) return;
        final key = _keyOf(ownerUid, tenantId as String);
        should.add(key);

        if (_invitedDocSubs.containsKey(key)) return;
        _invitedDocSubs[key] = FirebaseFirestore.instance
            .collection(ownerUid)
            .doc(tenantId)
            .snapshots()
            .listen((ds) {
              if (ds.exists) {
                _rows[key] = _TenantRow(
                  ownerUid: ownerUid,
                  tenantId: ds.id,
                  data: ds.data() ?? {},
                  invited: ownerUid != uid,
                );
              } else {
                _rows.remove(key);
              }
              _emit();
            });
      });

      for (final key
          in _invitedDocSubs.keys.where((k) => !should.contains(k)).toList()) {
        _invitedDocSubs.remove(key)?.cancel();
        _rows.remove(key);
      }
      _emit();
    });
  }

  @override
  void dispose() {
    for (final s in _invitedDocSubs.values) {
      s.cancel();
    }
    _invitedDocSubs.clear();
    _ownedSub?.cancel();
    _invitedIndexSub?.cancel();
    _ctrl.close();
    super.dispose();
  }

  // -------- UI --------
  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: SafeArea(
        child: StreamBuilder<List<_TenantRow>>(
          stream: _stream,
          builder: (context, snap) {
            final rows = snap.data ?? const <_TenantRow>[];

            // 選択キーを同定（初回のみ）
            if (_selectedKey == null &&
                _selectedId != null &&
                rows.isNotEmpty) {
              final me = _uid;
              final _TenantRow hit = rows.firstWhere(
                (r) => r.tenantId == _selectedId && r.ownerUid == me,
                orElse: () => rows.firstWhere(
                  (r) => r.tenantId == _selectedId,
                  orElse: () => rows.first,
                ),
              );
              _selectedKey = _keyOf(hit.ownerUid, hit.tenantId);
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ヘッダー
                DrawerHeader(
                  margin: EdgeInsets.zero,
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '店舗選択',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${rows.length} 件',
                        style: const TextStyle(color: Colors.black54),
                      ),
                      const Spacer(),
                      FilledButton.icon(
                        onPressed: _onCreateTenantPressed,
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('新規作成'),
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.black,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                if (snap.connectionState == ConnectionState.waiting)
                  const LinearProgressIndicator(minHeight: 2),

                // 一覧
                Expanded(
                  child: ListView.separated(
                    itemCount: rows.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (ctx, i) {
                      final r = rows[i];
                      final name = (r.data['name'] ?? '(no name)').toString();
                      final key = _keyOf(r.ownerUid, r.tenantId);
                      final selected = key == _selectedKey;
                      final isDraft = (r.data['status'] == 'nonactive');

                      return ListTile(
                        dense: false,
                        title: Row(
                          children: [
                            if (r.invited) ...[
                              const Icon(Icons.group_add, size: 16),
                              const SizedBox(width: 6),
                            ],
                            Expanded(
                              child: Text(
                                name,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        subtitle: isDraft
                            ? const Text(
                                '下書き（未完了）',
                                style: TextStyle(color: Colors.black54),
                              )
                            : null,
                        selected: selected,
                        selectedTileColor: const Color(0x11000000),
                        onTap: () => _selectTenant(r),
                        trailing: TextButton(
                          onPressed: () => _resumeOnboarding(r),
                          child: Text(isDraft ? '続きから' : '登録状況'),
                        ),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _selectTenant(_TenantRow r) async {
    final key = _keyOf(r.ownerUid, r.tenantId);
    setState(() {
      _selectedKey = key;
      _selectedId = r.tenantId;
    });

    final name = (r.data['name'] ?? '') as String?;
    if (widget.onChangedEx != null) {
      widget.onChangedEx!(r.tenantId, name, r.ownerUid, r.invited);
    } else {
      widget.onChanged(r.tenantId, name);
    }

    // Drawer を閉じる
    if (mounted) Navigator.of(context).maybePop();
  }

  Future<void> _onCreateTenantPressed() async {
    // 先に Drawer を閉じてから親の作成フローを起動
    if (mounted) Navigator.of(context).maybePop();
    widget.onCreateTenant();
  }

  Future<void> _resumeOnboarding(_TenantRow r) async {
    // ここでは選択だけして親へ通知（親側で必要ならオンボーディングを開始）
    await _selectTenant(r);
  }
}

// 行モデル
class _TenantRow {
  final String ownerUid;
  final String tenantId;
  final Map<String, dynamic> data;
  final bool invited;
  const _TenantRow({
    required this.ownerUid,
    required this.tenantId,
    required this.data,
    required this.invited,
  });
}
