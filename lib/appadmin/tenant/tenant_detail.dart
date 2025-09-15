// ======= 店舗詳細 =======
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:yourpay/appadmin/admin_dashboard_screen.dart';
import 'package:yourpay/appadmin/util.dart';

class AdminTenantDetailPage extends StatelessWidget {
  final String ownerUid;
  final String tenantId;
  final String tenantName;

  const AdminTenantDetailPage({
    super.key,
    required this.ownerUid,
    required this.tenantId,
    required this.tenantName,
  });

  String _yen(int v) => '¥${v.toString()}';
  String _ymdhm(DateTime d) =>
      '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final tenantRef = FirebaseFirestore.instance
        .collection(ownerUid)
        .doc(tenantId);
    final indexRef = FirebaseFirestore.instance
        .collection('tenantIndex')
        .doc(tenantId);

    final pageTheme = Theme.of(context).copyWith(
      useMaterial3: true,
      // ベース色
      colorScheme: const ColorScheme.light(
        primary: Colors.black,
        onPrimary: Colors.white,
        secondary: Colors.black,
        onSecondary: Colors.white,
        surface: Colors.white,
        onSurface: Colors.black,
        background: Colors.white,
        onBackground: Colors.black,
      ),
      scaffoldBackgroundColor: Colors.white,

      // AppBar がスクロール時に色被りしないように
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
      ),

      dividerTheme: const DividerThemeData(
        color: Colors.black12,
        thickness: 1,
        space: 1,
      ),

      // ボタン（Filled/Elevated/Text）を白黒固定
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
            side: const BorderSide(color: Colors.black),
          ),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
            side: const BorderSide(color: Colors.black),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: Colors.black),
      ),

      // Chip（FilterChip/ChoiceChip）も白黒
      chipTheme: ChipThemeData(
        backgroundColor: Colors.white,
        selectedColor: Colors.black,
        disabledColor: Colors.white,
        checkmarkColor: Colors.white,
        labelStyle: const TextStyle(color: Colors.black),
        secondaryLabelStyle: const TextStyle(color: Colors.white),
        side: const BorderSide(color: Colors.black),
        shape: const StadiumBorder(),
      ),

      // SegmentedButton を白黒
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: MaterialStateProperty.resolveWith(
            (s) => s.contains(MaterialState.selected)
                ? Colors.black
                : Colors.white,
          ),
          foregroundColor: MaterialStateProperty.resolveWith(
            (s) => s.contains(MaterialState.selected)
                ? Colors.white
                : Colors.black,
          ),
          side: MaterialStateProperty.all(
            const BorderSide(color: Colors.black),
          ),
          shape: MaterialStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
      ),
    );

    return Theme(
      data: pageTheme,
      child: Scaffold(
        appBar: AppBar(title: Text('店舗詳細：$tenantName')),
        body: ListView(
          children: [
            // 基本情報カード
            StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
              stream: indexRef.snapshots(),
              builder: (context, snap) {
                final m = snap.data?.data();
                final plan = (m?['subscription']?['plan'] ?? '').toString();
                final status = (m?['status'] ?? '').toString();
                final chargesEnabled =
                    m?['connect']?['charges_enabled'] == true;

                return myCard(
                  title: '基本情報',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _kv('Tenant ID', tenantId),
                      _kv('Owner UID', ownerUid),
                      _kv('Name', tenantName),
                      _kv('Plan', plan.isEmpty ? '-' : plan),
                      _kv('Status', status),
                      _kv('Stripe', chargesEnabled ? 'charges_enabled' : '—'),
                    ],
                  ),
                );
              },
            ),

            // 登録状況カード
            StatusCard(tenantId: tenantId),

            // 直近チップ
            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: tenantRef
                  .collection('tips')
                  .where('status', isEqualTo: 'succeeded')
                  .orderBy('createdAt', descending: true)
                  .limit(50)
                  .snapshots(),
              builder: (context, snap) {
                final docs = snap.data?.docs ?? const [];
                return myCard(
                  title: '直近のチップ（50件）',
                  child: Column(
                    children: docs.isEmpty
                        ? [const ListTile(title: Text('データがありません'))]
                        : docs.map((d) {
                            final m = d.data();
                            final amount = (m['amount'] as num?)?.toInt() ?? 0;
                            final emp = (m['employeeName'] ?? 'スタッフ')
                                .toString();
                            final ts = m['createdAt'];
                            final when = (ts is Timestamp) ? ts.toDate() : null;
                            return ListTile(
                              dense: true,
                              title: Text('${_yen(amount)}  /  $emp'),
                              subtitle: Text(when == null ? '-' : _ymdhm(when)),
                              trailing: Text(
                                (m['currency'] ?? 'JPY')
                                    .toString()
                                    .toUpperCase(),
                              ),
                            );
                          }).toList(),
                  ),
                );
              },
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        SizedBox(
          width: 120,
          child: Text(k, style: const TextStyle(color: Colors.black54)),
        ),
        Expanded(child: Text(v)),
      ],
    ),
  );
}
