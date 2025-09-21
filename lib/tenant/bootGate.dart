// boot_gate.dart
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:yourpay/tenant/loading.dart';
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
  bool get _isCurrentRoute => (ModalRoute.of(context)?.isCurrent ?? false);

  // ▼ 未認証時の「メール認証を拾うための」ポーリング
  Timer? _verifyTimer;
  int _verifyTicks = 0;
  static const int _verifyMaxTicks = 30; // 2秒 × 30 = 最大60秒

  @override
  void initState() {
    super.initState();
    _splashUntil = DateTime.now().add(_minSplash);
    Future.delayed(_minSplash, () {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _verifyTimer?.cancel();
    super.dispose();
  }

  bool get _holdSplash => DateTime.now().isBefore(_splashUntil);

  Future<void> _ensureMinSplash() async {
    final remain = _splashUntil.difference(DateTime.now());
    if (remain.inMilliseconds > 0) {
      await Future.delayed(remain);
    }
  }

  void _startVerifyWatcher() {
    if (_verifyTimer != null) return; // 既に起動済みなら何もしない
    _verifyTicks = 0;
    _verifyTimer = Timer.periodic(const Duration(seconds: 2), (t) async {
      _verifyTicks++;
      if (_verifyTicks > _verifyMaxTicks) {
        t.cancel();
        _verifyTimer = null;
        return;
      }
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        t.cancel();
        _verifyTimer = null;
        return;
      }
      try {
        await user.reload();
        // userChanges() を使っているので reload 後はストリームが発火し、build が呼ばれる
        if (!mounted) {
          t.cancel();
          _verifyTimer = null;
        }
      } catch (_) {
        // 無視して継続
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      // ★ ここが肝：メール認証・displayName 更新・reload でも流れる
      stream: FirebaseAuth.instance.userChanges(),
      builder: (context, snap) {
        // 起動直後の監視準備中 or 最低表示時間内はローディング固定
        if (snap.connectionState == ConnectionState.waiting || _holdSplash) {
          return const LoadingPage(message: '起動中…');
        }

        final user = snap.data;

        // 未ログイン
        if (user == null) {
          // 念のためポーリング停止
          _verifyTimer?.cancel();
          _verifyTimer = null;
          _navigated = false;
          return const LoginScreen();
        }

        // ログイン済みだが未認証 → ログイン画面を出しつつ、裏で emailVerified を監視
        if (!user.emailVerified) {
          _navigated = false; // 念のため
          _startVerifyWatcher(); // 2秒間隔で user.reload() → userChanges() が発火して再評価される
          return const LoginScreen();
        }

        // ここに来たら「認証済みのログイン状態」
        _verifyTimer?.cancel();
        _verifyTimer = null;

        if (!_navigated && _isCurrentRoute) {
          _navigated = true;
          WidgetsBinding.instance.addPostFrameCallback((_) async {
            if (!mounted || !_isCurrentRoute) return;
            await _ensureMinSplash();
            if (!mounted || !_isCurrentRoute) return;
            await _goToFirstTenantOrStore(context, user.uid);
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
