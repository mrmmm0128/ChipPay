// boot_gate.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:yourpay/loading.dart';
import 'package:yourpay/tenant/login_screens.dart';

class BootGate extends StatefulWidget {
  const BootGate({super.key});

  @override
  State<BootGate> createState() => _BootGateState();
}

class _BootGateState extends State<BootGate> {
  static const Duration _minSplash = Duration(seconds: 2);

  bool _navigated = false;
  late final DateTime _splashUntil;

  @override
  void initState() {
    super.initState();
    _splashUntil = DateTime.now().add(_minSplash);
    // 2秒後に再buildしてローディング解除できるように
    Future.delayed(_minSplash, () {
      if (mounted) setState(() {});
    });
  }

  bool get _holdSplash => DateTime.now().isBefore(_splashUntil);

  Future<void> _ensureMinSplash() async {
    final remain = _splashUntil.difference(DateTime.now());
    if (remain.inMilliseconds > 0) {
      await Future.delayed(remain);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snap) {
        // 起動直後の監視準備中 or 最低表示時間内はローディング固定
        if (snap.connectionState == ConnectionState.waiting || _holdSplash) {
          return const LoadingPage(message: '起動中…');
        }

        final user = snap.data;

        // 未ログイン or 未認証 → 2秒経過後にログイン画面
        if (user == null || !user.emailVerified) {
          return const LoginScreen();
        }

        // ログイン済み & 認証済み → 最初の店舗へ（最低2秒は表示してから）
        if (!_navigated) {
          _navigated = true;
          WidgetsBinding.instance.addPostFrameCallback((_) async {
            await _ensureMinSplash();
            if (mounted) {
              await _goToFirstTenantOrStore(context, user.uid);
            }
          });
        }

        // ナビゲート完了までローディング
        return const LoadingPage(message: 'データを確認しています…');
      },
    );
  }

  Future<void> _goToFirstTenantOrStore(BuildContext context, String uid) async {
    try {
      final qs = await FirebaseFirestore.instance
          .collection(uid)
          .limit(1)
          .get();
      if (!mounted) return;

      if (qs.docs.isEmpty) {
        Navigator.pushReplacementNamed(context, '/store');
        return;
      }

      final firstDoc = qs.docs.first;
      final data = firstDoc.data();
      final tenantId = firstDoc.id;
      final tenantName = (data['name'] as String?)?.trim();

      Navigator.pushReplacementNamed(
        context,
        '/store',
        arguments: <String, dynamic>{
          'tenantId': tenantId,
          if (tenantName != null && tenantName.isNotEmpty)
            'tenantName': tenantName,
        },
      );
    } catch (_) {
      if (!mounted) return;
      Navigator.pushReplacementNamed(context, '/store');
    }
  }
}
