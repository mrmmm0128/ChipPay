// tabs/settings_tab.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:firebase_auth/firebase_auth.dart'; // ★ 追加
import 'package:yourpay/tenant/store_detail/card_shell.dart';

class StoreSettingsTab extends StatefulWidget {
  final String tenantId;
  const StoreSettingsTab({super.key, required this.tenantId});

  @override
  State<StoreSettingsTab> createState() => _StoreSettingsTabState();
}

class _StoreSettingsTabState extends State<StoreSettingsTab> {
  final _functions = FirebaseFunctions.instanceFor(region: 'us-central1');
  List<Map<String, dynamic>> _invoices = [];
  bool _loadingInvoices = false;

  String? _selectedPlan; // 'A'|'B'|'C'
  final _lineUrlCtrl = TextEditingController();
  final _reviewUrlCtrl = TextEditingController();
  bool _updatingPlan = false;
  bool _savingExtras = false;

  final _storePercentCtrl = TextEditingController();
  final _storeFixedCtrl = TextEditingController();
  bool _savingStoreCut = false;
  bool _loggingOut = false;
  String? _thanksPhotoUrl;
  String? _thanksVideoUrl;
  bool _uploadingPhoto = false;
  bool _uploadingVideo = false;
  Uint8List? _thanksPhotoPreviewBytes; // 新規選択時のプレビュー用（任意）

  @override
  void dispose() {
    _lineUrlCtrl.dispose();
    _reviewUrlCtrl.dispose();
    _storePercentCtrl.dispose();
    _storeFixedCtrl.dispose();
    super.dispose();
  }

  // 初期表示に Firestore から読み込む（周辺のスナップショットがあるならそこから代入でもOK）
  Future<void> _loadCPerks(DocumentReference tenantRef) async {
    final snap = await tenantRef.get();
    final data = (snap.data() as Map<String, dynamic>?);
    final cPerks = (data?['c_perks'] as Map<String, dynamic>?) ?? {};
    setState(() {
      _thanksPhotoUrl = cPerks['thanksPhotoUrl'] as String?;
      _thanksVideoUrl = cPerks['thanksVideoUrl'] as String?;
    });
  }

  Future<void> _pickAndUploadPhoto(DocumentReference tenantRef) async {
    try {
      setState(() => _uploadingPhoto = true);
      final tenantId = tenantRef.id;

      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['jpg', 'jpeg', 'png'],
        allowMultiple: false,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;

      final file = result.files.single;
      final bytes = file.bytes;
      if (bytes == null) return;

      // サイズ制限（例: 5MB）
      const maxBytes = 5 * 1024 * 1024;
      if (bytes.length > maxBytes) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('画像サイズが大きすぎます（最大 5MB）。')),
          );
        }
        return;
      }

      // 旧ファイルがあれば先に削除（任意）
      if (_thanksPhotoUrl != null) {
        try {
          await FirebaseStorage.instance.refFromURL(_thanksPhotoUrl!).delete();
        } catch (_) {}
      }

      final ext = (file.extension ?? 'jpg').toLowerCase();
      final contentType = ext == 'png' ? 'image/png' : 'image/jpeg';
      final filename =
          'gratitude_${DateTime.now().millisecondsSinceEpoch}.$ext';
      final ref = FirebaseStorage.instance.ref(
        'tenants/$tenantId/c_plan/$filename',
      );

      await ref.putData(bytes, SettableMetadata(contentType: contentType));
      final url = await ref.getDownloadURL();

      // Firestore に即保存（「あとで使える」状態を担保）
      await tenantRef.update({
        'c_perks.thanksPhotoUrl': url,
        'c_perks.updatedAt': FieldValue.serverTimestamp(),
      });

      setState(() {
        _thanksPhotoUrl = url;
        _thanksPhotoPreviewBytes = bytes; // その場でのプレビューに使いたい場合
      });

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('感謝の写真を保存しました。')));
      }
    } finally {
      if (mounted) setState(() => _uploadingPhoto = false);
    }
  }

  Future<void> _pickAndUploadVideo(DocumentReference tenantRef) async {
    try {
      setState(() => _uploadingVideo = true);
      final tenantId = tenantRef.id;

      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['mp4', 'mov', 'webm'],
        allowMultiple: false,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;

      final file = result.files.single;
      final bytes = file.bytes;
      if (bytes == null) return;

      // サイズ制限（例: 50MB）
      const maxBytes = 50 * 1024 * 1024;
      if (bytes.length > maxBytes) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('動画サイズが大きすぎます（最大 50MB）。')),
          );
        }
        return;
      }

      // 旧ファイル削除（任意）
      if (_thanksVideoUrl != null) {
        try {
          await FirebaseStorage.instance.refFromURL(_thanksVideoUrl!).delete();
        } catch (_) {}
      }

      final ext = (file.extension ?? 'mp4').toLowerCase();
      final contentType = switch (ext) {
        'mov' => 'video/quicktime',
        'webm' => 'video/webm',
        _ => 'video/mp4',
      };
      final filename =
          'gratitude_${DateTime.now().millisecondsSinceEpoch}.$ext';
      final ref = FirebaseStorage.instance.ref(
        'tenants/$tenantId/c_plan/$filename',
      );

      await ref.putData(bytes, SettableMetadata(contentType: contentType));
      final url = await ref.getDownloadURL();

      await tenantRef.update({
        'c_perks.thanksVideoUrl': url,
        'c_perks.updatedAt': FieldValue.serverTimestamp(),
      });

      setState(() {
        _thanksVideoUrl = url;
      });

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('感謝の動画を保存しました。')));
      }
    } finally {
      if (mounted) setState(() => _uploadingVideo = false);
    }
  }

  Future<void> _deleteThanksPhoto(DocumentReference tenantRef) async {
    if (_thanksPhotoUrl == null) return;
    try {
      await FirebaseStorage.instance.refFromURL(_thanksPhotoUrl!).delete();
    } catch (_) {}
    await tenantRef.update({
      'c_perks.thanksPhotoUrl': FieldValue.delete(),
      'c_perks.updatedAt': FieldValue.serverTimestamp(),
    });
    setState(() {
      _thanksPhotoUrl = null;
      _thanksPhotoPreviewBytes = null;
    });
  }

  Future<void> _deleteThanksVideo(DocumentReference tenantRef) async {
    if (_thanksVideoUrl == null) return;
    try {
      await FirebaseStorage.instance.refFromURL(_thanksVideoUrl!).delete();
    } catch (_) {}
    await tenantRef.update({
      'c_perks.thanksVideoUrl': FieldValue.delete(),
      'c_perks.updatedAt': FieldValue.serverTimestamp(),
    });
    setState(() {
      _thanksVideoUrl = null;
    });
  }

  Future<void> _logout() async {
    if (_loggingOut) return;
    setState(() => _loggingOut = true);
    try {
      await FirebaseAuth.instance.signOut();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('ログアウトしました')));
      // ルーティングはアプリ側の auth 監視に任せる想定
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('ログアウトに失敗: $e')));
    } finally {
      if (mounted) setState(() => _loggingOut = false);
    }
  }

  Future<void> _loadInvoices(String tenantId) async {
    setState(() => _loadingInvoices = true);
    try {
      final fn = FirebaseFunctions.instanceFor(
        region: 'us-central1',
      ).httpsCallable('listInvoices');
      final res = await fn.call({'tenantId': tenantId, 'limit': 24});
      final data = (res.data as Map)['invoices'] as List<dynamic>? ?? [];
      _invoices = data.cast<Map<String, dynamic>>();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('請求履歴の読込に失敗: $e')));
      }
    } finally {
      if (mounted) setState(() => _loadingInvoices = false);
    }
  }

  DateTime _firstDayOfNextMonth([DateTime? base]) {
    final b = base ?? DateTime.now();
    final y = (b.month == 12) ? b.year + 1 : b.year;
    final m = (b.month == 12) ? 1 : b.month + 1;
    return DateTime(y, m, 1);
  }

  Future<void> _saveStoreCut(DocumentReference tenantRef) async {
    final percentText = _storePercentCtrl.text.trim();
    final fixedText = _storeFixedCtrl.text.trim();

    double p = double.tryParse(percentText.replaceAll('％', '')) ?? 0.0;
    int f = int.tryParse(fixedText.replaceAll('円', '')) ?? 0;

    if (p.isNaN || p < 0) p = 0;
    if (p > 100) p = 100;
    if (f < 0) f = 0;

    setState(() => _savingStoreCut = true);
    try {
      final eff = _firstDayOfNextMonth();
      await tenantRef.set({
        // ★ 変更：即時反映せず pending に保存し、適用開始時刻を持たせる
        'storeDeductionPending': {
          'percent': p,
          'fixed': f,
          'effectiveFrom': Timestamp.fromDate(eff),
        },
      }, SetOptions(merge: true));

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '店舗控除（次回 ${eff.year}/${eff.month.toString().padLeft(2, '0')} から）を保存しました',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('店舗控除の保存に失敗: $e')));
    } finally {
      if (mounted) setState(() => _savingStoreCut = false);
    }
  }

  Future<void> _showStripeFeeNoticeAndProceed(
    DocumentReference tenantRef,
  ) async {
    if (_updatingPlan) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        title: const Text('ご確認ください', style: TextStyle(color: Colors.black87)),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Stripeを通じてチップを受け取る場合、Stripeの決済手数料として元金の2.4%が差し引かれます。（2.4%は標準の値であり、前後する可能性がございます。）',
              style: TextStyle(color: Colors.black87),
            ),
            SizedBox(height: 8),
            Text(
              'この手数料は運営手数料とは別に発生します。',
              style: TextStyle(color: Colors.black54),
            ),
          ],
        ),
        actionsPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル', style: TextStyle(color: Colors.black87)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('次へ'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _changePlan(tenantRef, _selectedPlan!);
    }
  }

  Future<void> _changePlan(DocumentReference tenantRef, String plan) async {
    setState(() => _updatingPlan = true);
    try {
      final res = await _functions
          .httpsCallable('createSubscriptionCheckout')
          .call({'tenantId': widget.tenantId, 'plan': plan});
      final data = res.data as Map;
      if (data['alreadySubscribed'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('すでに契約中です。支払い情報や請求はポータルで確認/変更できます。')),
        );
        await launchUrlString(data['portalUrl'], webOnlyWindowName: '_self');
      } else {
        await launchUrlString(data['url'], webOnlyWindowName: '_self');
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('プラン変更に失敗: $e')));
    } finally {
      if (mounted) setState(() => _updatingPlan = false);
    }
  }

  Future<void> _openCustomerPortal() async {
    try {
      final res = await _functions.httpsCallable('openCustomerPortal').call({
        'tenantId': widget.tenantId,
      });
      final url = (res.data as Map)['url'] as String;
      await launchUrlString(
        url,
        mode: LaunchMode.platformDefault,
        webOnlyWindowName: '_self',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('ポータルを開けませんでした: $e')));
    }
  }

  Future<void> _saveExtras(DocumentReference tenantRef) async {
    setState(() => _savingExtras = true);
    try {
      await tenantRef.set({
        'subscription': {
          'extras': {
            'lineOfficialUrl': _lineUrlCtrl.text.trim(),
            'googleReviewUrl': _reviewUrlCtrl.text.trim(),
          },
        },
      }, SetOptions(merge: true));

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('特典リンクを保存しました')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('保存に失敗: $e')));
      }
    } finally {
      if (mounted) setState(() => _savingExtras = false);
    }
  }

  Future<void> _inviteAdminDialog(DocumentReference tenantRef) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Colors.white, // ★ 白
        surfaceTintColor: Colors.transparent, // ★ 影色を消す
        title: const Text('管理者を招待', style: TextStyle(color: Colors.black87)),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(labelText: 'メールアドレス'),
          keyboardType: TextInputType.emailAddress,
          autofocus: true,
        ),
        actionsPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル', style: TextStyle(color: Colors.black87)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('招待'),
          ),
        ],
      ),
    );
    if (ok == true) {
      try {
        await _functions.httpsCallable('inviteTenantAdmin').call({
          'tenantId': widget.tenantId,
          'email': ctrl.text.trim(),
        });
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('招待を送信しました')));
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('招待に失敗: $e')));
      }
    }
  }

  Future<void> _removeAdmin(DocumentReference tenantRef, String uid) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Colors.white, // ★ 白
        surfaceTintColor: Colors.transparent,
        title: const Text('管理者を削除', style: TextStyle(color: Colors.black87)),
        content: Text(
          'このメンバー（$uid）を管理者から外しますか？',
          style: const TextStyle(color: Colors.black87),
        ),
        actionsPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル', style: TextStyle(color: Colors.black87)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      try {
        await _functions.httpsCallable('removeTenantMember').call({
          'tenantId': widget.tenantId,
          'uid': uid,
        });
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('削除に失敗: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // ★ 紫系の強調をすべて black87 に統一するローカルテーマ
    final base = Theme.of(context);
    final themed = base.copyWith(
      colorScheme: base.colorScheme.copyWith(
        primary: Colors.black87,
        secondary: Colors.black87,
        onPrimary: Colors.white,
        onSecondary: Colors.white,
        surfaceTint: Colors.transparent,
      ),
      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: Colors.black87,
        selectionColor: Color(0x33000000),
        selectionHandleColor: Colors.black87,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: Colors.black87,
      ),
      inputDecorationTheme: InputDecorationTheme(
        labelStyle: const TextStyle(color: Colors.black87),
        floatingLabelStyle: const TextStyle(
          color: Colors.black87,
          fontWeight: FontWeight.w600,
        ),
        hintStyle: const TextStyle(color: Colors.black54),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Colors.black87, width: 1.2),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Colors.black26),
        ),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
      snackBarTheme: base.snackBarTheme.copyWith(
        backgroundColor: Colors.white,
        contentTextStyle: const TextStyle(color: Colors.black87),
        actionTextColor: Colors.black87,
        behavior: SnackBarBehavior.floating,
      ),
    );

    final primaryBtnStyle = FilledButton.styleFrom(
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    );
    final outlinedBtnStyle = OutlinedButton.styleFrom(
      foregroundColor: Colors.black87,
      side: const BorderSide(color: Colors.black87),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    );

    final tenantRef = FirebaseFirestore.instance
        .collection('tenants')
        .doc(widget.tenantId);

    return Theme(
      data: themed,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: StreamBuilder<DocumentSnapshot>(
          stream: tenantRef.snapshots(),
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(
                child: CircularProgressIndicator(), // ★ 黒87（テーマで上書き）
              );
            }
            final data = snap.data?.data() as Map<String, dynamic>? ?? {};
            final sub =
                (data['subscription'] as Map?)?.cast<String, dynamic>() ?? {};
            final currentPlan = (sub['plan'] as String?) ?? 'A';

            final periodEndTs = sub['currentPeriodEnd'];
            DateTime? periodEnd;
            if (periodEndTs is Timestamp) periodEnd = periodEndTs.toDate();

            final extras =
                (sub['extras'] as Map?)?.cast<String, dynamic>() ?? {};
            _selectedPlan ??= currentPlan;
            if (_lineUrlCtrl.text.isEmpty) {
              _lineUrlCtrl.text = extras['lineOfficialUrl'] as String? ?? '';
            }
            if (_reviewUrlCtrl.text.isEmpty) {
              _reviewUrlCtrl.text = extras['googleReviewUrl'] as String? ?? '';
            }
            final store =
                (data['storeDeduction'] as Map?)?.cast<String, dynamic>() ?? {};
            if (_storePercentCtrl.text.isEmpty && store['percent'] != null) {
              _storePercentCtrl.text = '${store['percent']}';
            }
            if (_storeFixedCtrl.text.isEmpty && store['fixed'] != null) {
              _storeFixedCtrl.text = '${store['fixed']}';
            }

            return ListView(
              children: [
                // アカウント情報ボタン（横長）
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.black,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                  ),
                  onPressed: () => Navigator.pushNamed(context, '/account'),
                  icon: const Icon(Icons.manage_accounts),
                  label: const Text('アカウント情報を確認'),
                ),
                const SizedBox(height: 16),

                const Text(
                  'サブスクリプション',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 8),
                CardShell(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            PlanChip(label: '現在', dark: true),
                            const SizedBox(width: 8),
                            Text(
                              'プラン $currentPlan',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                color: Colors.black87,
                              ),
                            ),
                            const Spacer(),
                            if (periodEnd != null)
                              Text(
                                '次回: ${periodEnd.year}/${periodEnd.month.toString().padLeft(2, '0')}/${periodEnd.day.toString().padLeft(2, '0')}',
                                style: const TextStyle(color: Colors.black54),
                              ),
                          ],
                        ),
                        const SizedBox(height: 16),

                        PlanPicker(
                          selected: _selectedPlan!,
                          onChanged: (v) => setState(() => _selectedPlan = v),
                        ),

                        if (_selectedPlan == 'C') ...[
                          const SizedBox(height: 16),
                          const Divider(height: 1),
                          const SizedBox(height: 16),
                          const Text(
                            'Cプランの特典（表示用リンク）',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _lineUrlCtrl,
                            decoration: const InputDecoration(
                              labelText: '公式LINEリンク（任意）',
                              hintText: 'https://lin.ee/xxxxx',
                            ),
                            keyboardType: TextInputType.url,
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _reviewUrlCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Googleレビューリンク（任意）',
                              hintText: 'https://g.page/r/xxxxx/review',
                            ),
                            keyboardType: TextInputType.url,
                          ),

                          // ===== 感謝メディア（写真／動画）ここから =====
                          const SizedBox(height: 16),
                          const Divider(height: 1),
                          const SizedBox(height: 16),
                          const Text(
                            'Cプランの特典（感謝の写真・動画）',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 8),

                          // 写真
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // プレビュー
                              Container(
                                width: 96,
                                height: 96,
                                color: Colors.grey.shade200,
                                alignment: Alignment.center,
                                child: _uploadingPhoto
                                    ? const SizedBox(
                                        width: 24,
                                        height: 24,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : (() {
                                        if (_thanksPhotoPreviewBytes != null) {
                                          return Image.memory(
                                            _thanksPhotoPreviewBytes!,
                                            fit: BoxFit.cover,
                                          );
                                        }
                                        if (_thanksPhotoUrl != null) {
                                          return Image.network(
                                            _thanksPhotoUrl!,
                                            fit: BoxFit.cover,
                                          );
                                        }
                                        return const Icon(
                                          Icons.photo,
                                          size: 32,
                                        );
                                      })(),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text('感謝の写真（JPG/PNG・5MBまで）'),
                                    const SizedBox(height: 8),
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: [
                                        FilledButton.icon(
                                          onPressed: _uploadingPhoto
                                              ? null
                                              : () => _pickAndUploadPhoto(
                                                  tenantRef,
                                                ),
                                          icon: const Icon(Icons.file_upload),
                                          label: Text(
                                            _thanksPhotoUrl == null
                                                ? '写真を選ぶ'
                                                : '写真を差し替え',
                                          ),
                                        ),
                                        if (_thanksPhotoUrl != null)
                                          OutlinedButton.icon(
                                            onPressed: _uploadingPhoto
                                                ? null
                                                : () => _deleteThanksPhoto(
                                                    tenantRef,
                                                  ),
                                            icon: const Icon(
                                              Icons.delete_outline,
                                            ),
                                            label: const Text('写真を削除'),
                                          ),
                                        if (_thanksPhotoUrl != null)
                                          OutlinedButton.icon(
                                            onPressed: () => launchUrlString(
                                              _thanksPhotoUrl!,
                                              mode: LaunchMode
                                                  .externalApplication,
                                            ),
                                            icon: const Icon(Icons.open_in_new),
                                            label: const Text('写真を開く'),
                                          ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(height: 16),

                          // 動画
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: 96,
                                height: 96,
                                color: Colors.grey.shade200,
                                alignment: Alignment.center,
                                child: _uploadingVideo
                                    ? const SizedBox(
                                        width: 24,
                                        height: 24,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.movie, size: 32),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text('感謝の動画（MP4/MOV/WEBM・50MBまで）'),
                                    const SizedBox(height: 8),
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: [
                                        FilledButton.icon(
                                          onPressed: _uploadingVideo
                                              ? null
                                              : () => _pickAndUploadVideo(
                                                  tenantRef,
                                                ),
                                          icon: const Icon(Icons.file_upload),
                                          label: Text(
                                            _thanksVideoUrl == null
                                                ? '動画を選ぶ'
                                                : '動画を差し替え',
                                          ),
                                        ),
                                        if (_thanksVideoUrl != null)
                                          OutlinedButton.icon(
                                            onPressed: _uploadingVideo
                                                ? null
                                                : () => _deleteThanksVideo(
                                                    tenantRef,
                                                  ),
                                            icon: const Icon(
                                              Icons.delete_outline,
                                            ),
                                            label: const Text('動画を削除'),
                                          ),
                                        if (_thanksVideoUrl != null)
                                          OutlinedButton.icon(
                                            onPressed: () => launchUrlString(
                                              _thanksVideoUrl!,
                                              mode: LaunchMode
                                                  .externalApplication,
                                            ),
                                            icon: const Icon(Icons.open_in_new),
                                            label: const Text('動画を開く'),
                                          ),
                                      ],
                                    ),
                                    if (_thanksVideoUrl != null) ...[
                                      const SizedBox(height: 4),
                                      Text(
                                        '保存URL: $_thanksVideoUrl',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.bodySmall,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          ),

                          // ===== 感謝メディアここまで =====
                          const SizedBox(height: 12),
                          Align(
                            alignment: Alignment.centerRight,
                            child: FilledButton.icon(
                              style: primaryBtnStyle,
                              onPressed: _savingExtras
                                  ? null
                                  : () => _saveExtras(tenantRef),
                              icon: _savingExtras
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Icon(Icons.link),
                              // ここは「特典を保存」に名称変更（リンク＋メディア全体の保存の意味合いに）
                              label: const Text('特典を保存'),
                            ),
                          ),
                        ],

                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: FilledButton.icon(
                                style: primaryBtnStyle,
                                onPressed: _updatingPlan
                                    ? null
                                    : () => _showStripeFeeNoticeAndProceed(
                                        tenantRef,
                                      ),
                                icon: _updatingPlan
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.white, // 黒ボタン上なので白
                                        ),
                                      )
                                    : const Icon(Icons.autorenew),
                                label: Text(
                                  currentPlan == _selectedPlan
                                      ? '再設定/再購読'
                                      : '変更',
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            OutlinedButton.icon(
                              style: outlinedBtnStyle,
                              onPressed: _openCustomerPortal,
                              icon: const Icon(Icons.credit_card),
                              label: const Text('サブスク登録を管理'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 24),
                const Text(
                  "スタッフから差し引く金額を設定します。",
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 8),
                CardShell(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'スタッフにチップを満額渡しますか？',
                          style: TextStyle(color: Colors.black87),
                        ),
                        const SizedBox(height: 12),
                        const SizedBox(height: 8),
                        Builder(
                          builder: (context) {
                            final pending =
                                (data['storeDeductionPending'] as Map?)
                                    ?.cast<String, dynamic>() ??
                                const {};
                            DateTime? eff;
                            final ts = pending['effectiveFrom'];
                            if (ts is Timestamp) eff = ts.toDate();
                            eff ??= _firstDayOfNextMonth();
                            final ym =
                                '${eff.year}/${eff.month.toString().padLeft(2, '0')}';
                            return Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF5F5F5),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: Colors.black12),
                              ),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.schedule,
                                    size: 18,
                                    color: Colors.black54,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      'この変更は「翌月分（$ym）の明細」から自動適用されます。',
                                      style: const TextStyle(
                                        color: Colors.black87,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _storePercentCtrl,
                                decoration: const InputDecoration(
                                  labelText: 'スタッフから店舗が差し引く金額（％）',
                                  hintText: '例: 10 または 12.5',
                                  suffixText: '%',
                                ),
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      signed: false,
                                      decimal: true,
                                    ),
                                inputFormatters: [
                                  FilteringTextInputFormatter.allow(
                                    RegExp(r'[0-9.]'),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Align(
                          alignment: Alignment.centerRight,
                          child: FilledButton.icon(
                            onPressed: _savingStoreCut
                                ? null
                                : () => _saveStoreCut(tenantRef),
                            icon: _savingStoreCut
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white, // 黒ボタン上なので白
                                    ),
                                  )
                                : const Icon(Icons.save),
                            label: const Text('店舗控除を保存'),
                            style: FilledButton.styleFrom(
                              backgroundColor: Colors.black,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 24),
                const Text(
                  '請求履歴',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 8),
                CardShell(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Align(
                          alignment: Alignment.centerRight,
                          child: OutlinedButton.icon(
                            onPressed: () => _loadInvoices(widget.tenantId),
                            icon: _loadingInvoices
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      // ★ テーマで黒87になる
                                    ),
                                  )
                                : const Icon(Icons.refresh),
                            label: const Text('更新'),
                          ),
                        ),
                        const SizedBox(height: 8),
                        if (_invoices.isEmpty && !_loadingInvoices)
                          const Text(
                            '請求履歴はまだありません',
                            style: TextStyle(color: Colors.black87),
                          ),
                        if (_invoices.isNotEmpty)
                          ..._invoices.map((inv) {
                            final amount =
                                inv['amount_paid'] ?? inv['amount_due'] ?? 0;
                            final cur = (inv['currency'] ?? 'jpy')
                                .toString()
                                .toUpperCase();
                            final number = inv['number'] ?? inv['id'];
                            final url = inv['hosted_invoice_url'];
                            final created = DateTime.fromMillisecondsSinceEpoch(
                              (inv['created'] ?? 0) * 1000,
                            );
                            final ym =
                                '${created.year}/${created.month.toString().padLeft(2, '0')}';

                            return ListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Text('請求 #$number（$ym）'),
                              subtitle: Text(
                                '支払額: ${(amount / 100).toStringAsFixed(2)} $cur  •  状態: ${inv['status']}',
                              ),
                              trailing: (url != null)
                                  ? IconButton(
                                      icon: const Icon(Icons.open_in_new),
                                      onPressed: () => launchUrlString(
                                        url,
                                        mode: LaunchMode.platformDefault,
                                        webOnlyWindowName: '_self',
                                      ),
                                    )
                                  : null,
                            );
                          }),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 16),
                const Text(
                  '管理者一覧',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 8),
                CardShell(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                    child: Column(
                      children: [
                        StreamBuilder<QuerySnapshot>(
                          stream: tenantRef.collection('members').snapshots(),
                          builder: (context, memSnap) {
                            final members = memSnap.data?.docs ?? [];
                            if (memSnap.hasData && members.isNotEmpty) {
                              return AdminList(
                                entries: members.map((m) {
                                  final md = m.data() as Map<String, dynamic>;
                                  return AdminEntry(
                                    uid: m.id,
                                    email: (md['email'] as String?) ?? '',
                                    name: (md['displayName'] as String?) ?? '',
                                    role: (md['role'] as String?) ?? 'admin',
                                  );
                                }).toList(),
                                onRemove: (uid) => _removeAdmin(tenantRef, uid),
                              );
                            }

                            final uids =
                                (data['memberUids'] as List?)?.cast<String>() ??
                                const <String>[];
                            if (uids.isEmpty) {
                              return const ListTile(
                                title: Text(
                                  '管理者がいません',
                                  style: TextStyle(color: Colors.black87),
                                ),
                                subtitle: Text(
                                  '右上の追加ボタンから招待できます',
                                  style: TextStyle(color: Colors.black87),
                                ),
                              );
                            }
                            return AdminList(
                              entries: uids
                                  .map(
                                    (u) => AdminEntry(
                                      uid: u,
                                      email: '',
                                      name: '',
                                      role: 'admin',
                                    ),
                                  )
                                  .toList(),
                              onRemove: (uid) => _removeAdmin(tenantRef, uid),
                            );
                          },
                        ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: () => _inviteAdminDialog(tenantRef),
                            icon: const Icon(Icons.person_add_alt_1),
                            label: const Text('管理者を追加（メール招待）'),
                          ),
                        ),

                        // 一番下にログアウト
                        const SizedBox(height: 24),
                        SafeArea(
                          top: false,
                          child: SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              onPressed: _loggingOut ? null : _logout,
                              icon: _loggingOut
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        // ★ テーマで黒87になる
                                      ),
                                    )
                                  : const Icon(Icons.logout),
                              label: const Text('ログアウト'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.black87,
                                side: const BorderSide(color: Colors.black87),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 12,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
