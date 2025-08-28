// lib/public/public_staff_qr_list_page.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';

class PublicStaffQrListPage extends StatefulWidget {
  const PublicStaffQrListPage({super.key});

  @override
  State<PublicStaffQrListPage> createState() => _PublicStaffQrListPageState();
}

class _PublicStaffQrListPageState extends State<PublicStaffQrListPage> {
  String? tenantId;

  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    tenantId = _readTenantIdFromUrl();
    _searchCtrl.addListener(() {
      setState(() => _query = _searchCtrl.text.trim().toLowerCase());
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  String? _readTenantIdFromUrl() {
    final uri = Uri.base;
    final frag = uri.fragment; // 例: "/qr-all?t=xxx"
    final qi = frag.indexOf('?');
    final qp = <String, String>{}..addAll(uri.queryParameters);
    if (qi >= 0) {
      qp.addAll(Uri.splitQueryString(frag.substring(qi + 1)));
    }
    return qp['t'];
  }

  @override
  Widget build(BuildContext context) {
    if (tenantId == null || tenantId!.isEmpty) {
      return const Scaffold(body: Center(child: Text('tenantId が見つかりません')));
    }

    final q = FirebaseFirestore.instance
        .collection('tenants')
        .doc(tenantId)
        .collection('employees')
        .orderBy('createdAt', descending: true);

    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 0,
        title: const Text(
          'スタッフQR一覧',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      body: Column(
        children: [
          // 使い方の簡単な説明
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.black12),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x0F000000),
                    blurRadius: 8,
                    offset: Offset(0, 3),
                  ),
                ],
              ),
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.qr_code_2, color: Colors.black87),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '各スタッフの「QRポスターを作る」ボタンから、本人ページへ誘導するQR付きポスターを作成できます。'
                      '\n・顔写真と名前を確認して該当のカードを選んでください'
                      '\n・PDFをダウンロードして印刷、店内に掲示してください',
                      style: const TextStyle(
                        color: Colors.black87,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // 名前検索ボックス
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: '名前で検索',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchCtrl.clear();
                          FocusScope.of(context).unfocus();
                        },
                      ),
                filled: true,
                fillColor: Colors.white,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Colors.black12),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Colors.black12),
                ),
              ),
            ),
          ),

          const SizedBox(height: 4),

          // 一覧
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: q.snapshots(),
              builder: (context, snap) {
                if (snap.hasError) {
                  return Center(child: Text('読み込みエラー: ${snap.error}'));
                }
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                final all = snap.data!.docs;
                final filtered = all.where((doc) {
                  final d = doc.data() as Map<String, dynamic>;
                  final name = (d['name'] ?? '').toString().toLowerCase();
                  return _query.isEmpty || name.contains(_query);
                }).toList();

                if (filtered.isEmpty) {
                  return const Center(child: Text('該当するスタッフがいません'));
                }

                return LayoutBuilder(
                  builder: (context, c) {
                    final w = c.maxWidth;
                    final cols = w >= 1100 ? 4 : (w >= 800 ? 3 : 2);

                    return GridView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: cols,
                        mainAxisSpacing: 12, // ← 余白を少し詰める
                        crossAxisSpacing: 12, // ← 余白を少し詰める
                        childAspectRatio: 1.0, // ← 縦長すぎを是正（余白増大の抑制）
                      ),
                      itemCount: filtered.length,
                      itemBuilder: (_, i) {
                        final doc = filtered[i];
                        final d = doc.data() as Map<String, dynamic>;
                        final empId = doc.id;
                        final name = (d['name'] ?? '') as String;
                        final photoUrl = (d['photoUrl'] ?? '') as String;

                        return _StaffCard(
                          name: name,
                          photoUrl: photoUrl,
                          onMakeQr: () async {
                            final base = Uri.base;
                            final origin =
                                '${base.scheme}://${base.host}${base.hasPort ? ':${base.port}' : ''}';
                            final url =
                                '$origin/#/qr-builder?t=$tenantId&e=$empId';
                            await launchUrlString(url);
                          },
                        );
                      },
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _StaffCard extends StatelessWidget {
  final String name;
  final String photoUrl;
  final VoidCallback onMakeQr;

  const _StaffCard({
    required this.name,
    required this.photoUrl,
    required this.onMakeQr,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      elevation: 4,
      shadowColor: const Color(0x14000000),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onMakeQr,
        child: Padding(
          padding: const EdgeInsets.all(10), // ← 内側余白を控えめに
          child: Column(
            children: [
              CircleAvatar(
                radius: 36, // ← 少し小さめに
                backgroundImage: photoUrl.isNotEmpty
                    ? NetworkImage(photoUrl)
                    : null,
                child: photoUrl.isEmpty
                    ? const Icon(Icons.person, size: 32)
                    : null,
              ),
              const SizedBox(height: 8),
              Text(
                name.isNotEmpty ? name : 'スタッフ',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
                textAlign: TextAlign.center,
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
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
                  onPressed: onMakeQr,
                  child: const Text('QRポスターを作る'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
