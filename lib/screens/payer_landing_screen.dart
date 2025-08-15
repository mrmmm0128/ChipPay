import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class PayerLandingScreen extends StatefulWidget {
  final String sessionId;
  const PayerLandingScreen({super.key, required this.sessionId});

  @override
  State<PayerLandingScreen> createState() => _PayerLandingScreenState();
}

class _PayerLandingScreenState extends State<PayerLandingScreen> {
  String? message;

  @override
  void initState() {
    super.initState();
    _jump();
  }

  Future<void> _jump() async {
    if (widget.sessionId.isEmpty) {
      setState(() => message = 'リンクが不正です');
      return;
    }
    final doc = await FirebaseFirestore.instance
        .collection('paymentSessions')
        .doc(widget.sessionId)
        .get();
    if (!doc.exists) {
      setState(() => message = 'リンクが無効です');
      return;
    }
    final url = (doc.data()!['stripeCheckoutUrl'] as String?) ?? '';
    if (url.isEmpty) {
      setState(() => message = '開始できませんでした');
      return;
    }
    final ok = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!ok) setState(() => message = '決済ページを開けませんでした');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: message == null
            ? const CircularProgressIndicator()
            : Text(message!),
      ),
    );
  }
}
