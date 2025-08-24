// lib/public/public_staff_qr_list_page.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';

class PublicStaffQrListPage extends StatelessWidget {
  const PublicStaffQrListPage({super.key});

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
    final tenantId = _readTenantIdFromUrl();
    if (tenantId == null || tenantId.isEmpty) {
      return const Scaffold(body: Center(child: Text('tenantId が見つかりません')));
    }

    final q = FirebaseFirestore.instance
        .collection('tenants')
        .doc(tenantId)
        .collection('employees');

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
      body: StreamBuilder<QuerySnapshot>(
        stream: q.snapshots(),
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: Text('読み込みエラー: ${snap.error}'));
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final docs = snap.data!.docs;
          if (docs.isEmpty) {
            return const Center(child: Text('公開対象のスタッフがいません'));
          }

          return LayoutBuilder(
            builder: (context, c) {
              final w = c.maxWidth;
              final cols = w >= 1100 ? 4 : (w >= 800 ? 3 : 2);

              return GridView.builder(
                padding: const EdgeInsets.all(16),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: cols,
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 16,
                  childAspectRatio: 0.85,
                ),
                itemCount: docs.length,
                itemBuilder: (_, i) {
                  final d = docs[i].data() as Map<String, dynamic>;
                  final empId = docs[i].id;
                  final name = (d['name'] ?? '') as String;
                  final photoUrl = (d['photoUrl'] ?? '') as String;

                  return Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x14000000),
                          blurRadius: 8,
                          offset: Offset(0, 3),
                        ),
                      ],
                    ),
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      children: [
                        CircleAvatar(
                          radius: 40,
                          backgroundImage: photoUrl.isNotEmpty
                              ? NetworkImage(photoUrl)
                              : null,
                          child: photoUrl.isEmpty
                              ? const Icon(Icons.person, size: 36)
                              : null,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          name.isNotEmpty ? name : 'スタッフ',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const Spacer(),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            style: FilledButton.styleFrom(
                              backgroundColor: Colors.black,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                            onPressed: () async {
                              final base = Uri.base;
                              final origin =
                                  '${base.scheme}://${base.host}${base.hasPort ? ':${base.port}' : ''}';
                              final url =
                                  '$origin/#/qr-builder?t=$tenantId&e=$empId';
                              // 同タブで遷移させるなら:
                              // Navigator.pushNamed(context, '/qr-builder?t=$tenantId&e=$empId'); // onGenerateRouteで対応していれば可
                              // もしくは Web想定でURL遷移:
                              await launchUrlString(
                                url,
                              ); // 別タブにしたいなら externalApplication
                            },
                            child: const Text('QRポスターを作る'),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}
