// lib/admin/accept_invite_screen.dart
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class AcceptInviteScreen extends StatefulWidget {
  const AcceptInviteScreen({super.key});
  @override
  State<AcceptInviteScreen> createState() => _AcceptInviteScreenState();
}

class _AcceptInviteScreenState extends State<AcceptInviteScreen> {
  String? tenantId, token;
  String? result;
  bool busy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final uri = Uri.base; // "#/admin-invite?tenantId=...&token=..."
    tenantId = uri.queryParameters['tenantId'];
    token = uri.queryParameters['token'];
  }

  Future<void> _accept() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      setState(() => result = 'まずログインしてください');
      return;
    }
    setState(() {
      busy = true;
      result = null;
    });
    try {
      final fn = FirebaseFunctions.instanceFor(
        region: 'us-central1',
      ).httpsCallable('acceptTenantAdmin');
      await fn.call({'tenantId': tenantId, 'token': token});
      setState(() => result = '承認しました。店舗管理者として追加されました。');
    } catch (e) {
      setState(() => result = '承認に失敗: $e');
    } finally {
      setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('管理者招待を承認')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('テナント: ${tenantId ?? "(不明)"}'),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: busy ? null : _accept,
                child: busy
                    ? const CircularProgressIndicator()
                    : const Text('承認する'),
              ),
              if (result != null) ...[
                const SizedBox(height: 12),
                Text(result!, textAlign: TextAlign.center),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
