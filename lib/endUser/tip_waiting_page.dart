import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:yourpay/endUser/tip_complete_page.dart';
import 'package:yourpay/endUser/tip_failed_page.dart';

class TipWaitingPage extends StatefulWidget {
  const TipWaitingPage({
    super.key,
    required this.sessionId,
    required this.tenantId,
    this.tenantName,
    required this.amount,
    this.employeeName,
    this.uid,
    required this.checkoutUrl,
  });

  final String sessionId;
  final String tenantId;
  final String? tenantName;
  final int amount;
  final String? employeeName;
  final String checkoutUrl;
  final String? uid;

  @override
  State<TipWaitingPage> createState() => _TipWaitingPageState();
}

class _TipWaitingPageState extends State<TipWaitingPage> {
  StreamSubscription<DocumentSnapshot>? _sub;
  bool _navigated = false;

  @override
  void initState() {
    super.initState();
    final ref = FirebaseFirestore.instance
        .collection('tenants')
        .doc(widget.tenantId)
        .collection('tipSessions')
        .doc(widget.sessionId);

    _sub = ref.snapshots().listen((doc) async {
      final data = doc.data();
      if (data == null) return;
      final status = (data['status'] as String?) ?? 'pending';
      if (_navigated) return;

      if (status == 'paid') {
        _navigated = true;
        if (!mounted) return;
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => TipCompletePage(
              tenantId: widget.tenantId,
              tenantName: widget.tenantName,
              amount: widget.amount,
              employeeName: widget.employeeName,
              uid: widget.uid,
            ),
          ),
        );
      } else if (status == 'failed' ||
          status == 'expired' ||
          status == 'canceled') {
        _navigated = true;
        if (!mounted) return;
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => TipFailedPage(
              reason: status,
              onRetry: () => launchUrlString(
                widget.checkoutUrl,
                mode: LaunchMode.externalApplication,
              ),
            ),
          ),
        );
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = '決済を確認中…（この画面は自動で切り替わります）';
    final who = (widget.employeeName?.isNotEmpty ?? false)
        ? 'スタッフ: ${widget.employeeName}'
        : (widget.tenantName != null ? '店舗: ${widget.tenantName}' : '店舗');

    return Scaffold(
      appBar: AppBar(title: const Text('決済中')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(title, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            Text(
              '$who へ ¥${widget.amount}',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => launchUrlString(
                widget.checkoutUrl,
                mode: LaunchMode.externalApplication,
              ),
              icon: const Icon(Icons.open_in_new),
              label: const Text('決済ページをもう一度開く'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () async {
                // 任意：中断マーク（使わないなら削ってOK）
                await FirebaseFirestore.instance
                    .collection('tipSessions')
                    .doc(widget.sessionId)
                    .set({
                      'status': 'canceled',
                      'canceledAt': FieldValue.serverTimestamp(),
                    }, SetOptions(merge: true));
                if (!mounted) return;
                Navigator.pop(context);
              },
              child: const Text('決済を中断する'),
            ),
          ],
        ),
      ),
    );
  }
}
