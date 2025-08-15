import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

class AdminConsoleScreen extends StatefulWidget {
  const AdminConsoleScreen({super.key});

  @override
  State<AdminConsoleScreen> createState() => _AdminConsoleScreenState();
}

class _AdminConsoleScreenState extends State<AdminConsoleScreen> {
  final nameCtrl = TextEditingController();
  final tenantIdCtrl = TextEditingController();
  final uidCtrl = TextEditingController();
  String status = 'active';
  bool _busy = false;

  Future<void> _createOrUpdateTenant() async {
    setState(() => _busy = true);
    try {
      await FirebaseFirestore.instance
          .collection('tenants')
          .doc(tenantIdCtrl.text.trim())
          .set({
            'name': nameCtrl.text.trim(),
            'status': status,
            'createdAt': FieldValue.serverTimestamp(),
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('テナントを保存しました')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('エラー: $e')));
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _setClaims() async {
    setState(() => _busy = true);
    try {
      final callable = FirebaseFunctions.instance.httpsCallable(
        'setUserClaims',
      );
      await callable.call({
        'uid': uidCtrl.text.trim(),
        'tenantId': tenantIdCtrl.text.trim(),
        'role': 'staff', // or 'superadmin'
      });
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Claims を設定しました')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('エラー: $e')));
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Admin Console')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('テナント登録/更新', style: TextStyle(fontSize: 18)),
            const SizedBox(height: 8),
            TextField(
              controller: tenantIdCtrl,
              decoration: const InputDecoration(labelText: 'Tenant ID（英数字）'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(labelText: 'Tenant 名'),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: status,
              items: const [
                DropdownMenuItem(value: 'active', child: Text('active')),
                DropdownMenuItem(value: 'suspended', child: Text('suspended')),
              ],
              onChanged: (v) => setState(() => status = v!),
              decoration: const InputDecoration(labelText: '状態'),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _busy ? null : _createOrUpdateTenant,
              icon: const Icon(Icons.save),
              label: const Text('保存'),
            ),
            const Divider(height: 32),
            const Text('ユーザーに Claims 付与', style: TextStyle(fontSize: 18)),
            const SizedBox(height: 8),
            TextField(
              controller: uidCtrl,
              decoration: const InputDecoration(labelText: 'Firebase UID'),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _busy ? null : _setClaims,
              icon: const Icon(Icons.verified_user),
              label: const Text('付与（role=staff, tenantId=上記）'),
            ),
          ],
        ),
      ),
    );
  }
}
