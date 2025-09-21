// tabs/settings_tab.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:yourpay/tenant/widget/store_setting/subscription_card.dart';
import 'package:yourpay/tenant/widget/store_staff/show_video_preview.dart';
import 'package:yourpay/tenant/widget/store_setting/c_perk.dart';
import 'package:yourpay/tenant/widget/store_setting/trial_progress_bar.dart';

class StoreSettingsTab extends StatefulWidget {
  final String tenantId;
  final String? ownerId;
  const StoreSettingsTab({super.key, required this.tenantId, this.ownerId});

  @override
  State<StoreSettingsTab> createState() => _StoreSettingsTabState();
}

class _StoreSettingsTabState extends State<StoreSettingsTab> {
  final _functions = FirebaseFunctions.instanceFor(region: 'us-central1');

  // -------- State --------
  List<Map<String, dynamic>> _invoices = [];
  bool _loadingInvoices = false;

  DateTime? _effectiveFromLocal; // 予約の適用開始（未指定なら翌月1日 0:00）

  String? _selectedPlan;
  String? _pendingPlan;
  bool _changingPlan = false;
  bool _updatingPlan = false;
  late final ValueNotifier<String> _tenantIdVN;
  final String? uid = FirebaseAuth.instance.currentUser?.uid;

  final _lineUrlCtrl = TextEditingController();
  final _reviewUrlCtrl = TextEditingController();
  bool _savingExtras = false;

  final _storePercentCtrl = TextEditingController();
  final _storeFixedCtrl = TextEditingController();
  bool _savingStoreCut = false;

  bool _loggingOut = false;

  String? _thanksPhotoUrl;
  String? _thanksVideoUrl;
  bool _uploadingPhoto = false;
  bool _uploadingVideo = false;
  Uint8List? _thanksPhotoPreviewBytes;
  bool ownerIsMe = true;

  bool? _connected = false;

  @override
  void initState() {
    super.initState();
    _effectiveFromLocal = _firstDayOfNextMonth();
    _loadConnectedOnce();
    _tenantIdVN = ValueNotifier(widget.tenantId);
    if (widget.ownerId == uid) {
      ownerIsMe = true;
    } else {
      ownerIsMe = false;
    }
  }

  @override
  void didUpdateWidget(covariant StoreSettingsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 親から tenantId が変わった時だけ再読込（タップでメニュー開いただけでは変わらない）
    if (oldWidget.tenantId != widget.tenantId) {
      setState(() {
        _connected = null; // ローディング表示へ
        _selectedPlan = null; // 表示を最新に
        _lineUrlCtrl.clear();
        _reviewUrlCtrl.clear();
        _storePercentCtrl.clear();
        _storeFixedCtrl.clear();
        _tenantIdVN.value = widget.tenantId;
      });
      _loadConnectedOnce();
    }
  }

  @override
  void dispose() {
    _lineUrlCtrl.dispose();
    _reviewUrlCtrl.dispose();
    _storePercentCtrl.dispose();
    _storeFixedCtrl.dispose();
    _tenantIdVN.dispose();
    super.dispose();
  }

  // -------- Handlers --------
  void _enterChangeMode() {
    setState(() {
      _changingPlan = true;
      _pendingPlan = _selectedPlan;
    });
  }

  void _cancelChangeMode() {
    setState(() {
      _changingPlan = false;
      _pendingPlan = null;
    });
  }

  void _onPlanChanged(String v) {
    if (!_changingPlan) return;
    setState(() => _pendingPlan = v);
  }

  Future<void> _applyPlanChange(
    DocumentReference<Map<String, dynamic>> tenantRef,
  ) async {
    if (_pendingPlan == null || _pendingPlan == _selectedPlan) return;
    setState(() => _selectedPlan = _pendingPlan);
    //await _showStripeFeeNoticeAndProceed(tenantRef);
    if (!mounted) return;
    setState(() {
      _changingPlan = false;
      _pendingPlan = null;
    });
  }

  Future<void> _pickAndUploadPhoto(
    DocumentReference<Map<String, dynamic>> tenantRef,
    DocumentReference<Map<String, dynamic>> thanksRef,
  ) async {
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

      // 5MB 制限
      const maxBytes = 5 * 1024 * 1024;
      if (bytes.length > maxBytes) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('画像サイズが大きすぎます（最大 5MB）。')),
          );
        }
        return;
      }

      // 旧ファイル削除（任意）
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
        '${widget.ownerId}/$tenantId/c_plan/$filename',
      );

      await ref.putData(bytes, SettableMetadata(contentType: contentType));
      final url = await ref.getDownloadURL();

      // Firestore へ即保存
      await tenantRef.update({
        'c_perks.thanksPhotoUrl': url,
        'c_perks.updatedAt': FieldValue.serverTimestamp(),
      });

      await thanksRef.set({
        'c_perks.thanksPhotoUrl': url,
        'c_perks.updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      setState(() {
        _thanksPhotoUrl = url;
        _thanksPhotoPreviewBytes = bytes;
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

  Future<void> _deleteThanksPhoto(
    DocumentReference<Map<String, dynamic>> tenantRef,
    DocumentReference<Map<String, dynamic>> thankRef,
  ) async {
    if (_thanksPhotoUrl == null) return;
    try {
      await FirebaseStorage.instance.refFromURL(_thanksPhotoUrl!).delete();
    } catch (_) {}
    await tenantRef.update({
      'c_perks.thanksPhotoUrl': FieldValue.delete(),
      'c_perks.updatedAt': FieldValue.serverTimestamp(),
    });
    await thankRef.update({
      'c_perks.thanksPhotoUrl': FieldValue.delete(),
      'c_perks.updatedAt': FieldValue.serverTimestamp(),
    });

    setState(() {
      _thanksPhotoUrl = null;
      _thanksPhotoPreviewBytes = null;
    });
  }

  // 管理者を招待（メール）
  Future<void> _inviteAdminDialog(
    DocumentReference<Map<String, dynamic>> tenantRef,
  ) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
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

  // 管理者を外す（確認ダイアログ付き）
  Future<void> _removeAdmin(
    DocumentReference<Map<String, dynamic>> tenantRef,
    String uid,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Colors.white,
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
          'uid': widget.ownerId,
        });
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('削除に失敗: $e')));
      }
    }
  }

  Future<void> _showInvoicesDialog(BuildContext context) async {
    if (_invoices.isEmpty && !_loadingInvoices) {
      await _loadInvoices(widget.tenantId);
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, sbSet) {
          String _fmtYMD(DateTime d) =>
              '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';

          Widget _list() {
            if (_loadingInvoices) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(),
                ),
              );
            }
            if (_invoices.isEmpty) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    '請求履歴はまだありません',
                    style: TextStyle(color: Colors.black87),
                  ),
                ),
              );
            }

            return ListView.separated(
              itemCount: _invoices.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final inv = _invoices[i];
                final amount =
                    (inv['amount_paid'] ?? inv['amount_due'] ?? 0) as num;
                final cur = (inv['currency'] ?? 'JPY').toString().toUpperCase();
                final number = (inv['number'] ?? inv['id'] ?? '').toString();
                final url = inv['hosted_invoice_url'] as String?;
                final pdf = inv['invoice_pdf'] as String?;

                int createdMs = 0;
                final createdRaw = inv['created'];
                if (createdRaw is int) {
                  createdMs = createdRaw * 1000;
                } else if (createdRaw is double) {
                  createdMs = (createdRaw * 1000).round();
                } else if (createdRaw is Timestamp) {
                  createdMs = createdRaw.millisecondsSinceEpoch;
                }
                final created = DateTime.fromMillisecondsSinceEpoch(createdMs);
                final ymd = _fmtYMD(created);

                return ListTile(
                  dense: true,
                  title: Text(
                    '請求 #$number（$ymd）',
                    style: const TextStyle(color: Colors.black87),
                  ),
                  subtitle: Text(
                    '支払額: ${(amount / 100).toStringAsFixed(2)} $cur  •  状態: ${inv['status']}',
                    style: const TextStyle(color: Colors.black54),
                  ),
                  trailing: Wrap(
                    spacing: 8,
                    children: [
                      if (pdf != null)
                        IconButton(
                          tooltip: 'PDFを開く',
                          icon: const Icon(Icons.picture_as_pdf),
                          onPressed: () => launchUrlString(
                            pdf,
                            mode: LaunchMode.externalApplication,
                          ),
                        ),
                      if (url != null)
                        IconButton(
                          tooltip: '請求書ページを開く',
                          icon: const Icon(Icons.open_in_new),
                          onPressed: () => launchUrlString(
                            url,
                            mode: LaunchMode.externalApplication,
                          ),
                        ),
                    ],
                  ),
                );
              },
            );
          }

          return AlertDialog(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
            title: Row(
              children: [
                const Text(
                  'サブスクリプション請求履歴',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                OutlinedButton.icon(
                  onPressed: _loadingInvoices
                      ? null
                      : () async {
                          await _loadInvoices(widget.tenantId);
                          sbSet(() {});
                        },
                  icon: _loadingInvoices
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                  label: const Text('更新'),
                ),
              ],
            ),
            content: SizedBox(width: 640, height: 460, child: _list()),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text(
                  '閉じる',
                  style: TextStyle(color: Colors.black87),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> logout() async {
    if (_loggingOut) return;
    setState(() => _loggingOut = true);
    try {
      await FirebaseAuth.instance.signOut();
      if (!mounted) return;

      // 画面スタックを全消しして /login (BootGate) へ
      Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
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

  Future<void> _saveStoreCut(
    DocumentReference<Map<String, dynamic>> tenantRef,
  ) async {
    final percentText = _storePercentCtrl.text.trim();
    final fixedText = _storeFixedCtrl.text.trim();

    double p = double.tryParse(percentText.replaceAll('％', '')) ?? 0.0;
    int f = int.tryParse(fixedText.replaceAll('円', '')) ?? 0;

    if (p.isNaN || p < 0) p = 0;
    if (p > 100) p = 100;

    var eff = _effectiveFromLocal ?? _firstDayOfNextMonth();
    final now = DateTime.now();
    if (eff.isBefore(now)) {
      eff = now;
    }

    setState(() => _savingStoreCut = true);
    try {
      await tenantRef.set({
        'storeDeduction': {
          'percent': p,

          //'effectiveFrom': Timestamp.fromDate(eff),
        },
      }, SetOptions(merge: true));

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('店舗が差し引く金額割合を保存しました')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('店舗控除の保存に失敗: $e')));
    } finally {
      if (mounted) setState(() => _savingStoreCut = false);
    }
  }

  // Future<void> _showStripeFeeNoticeAndProceed(
  //   DocumentReference<Map<String, dynamic>> tenantRef,
  // ) async {
  //   if (_updatingPlan) return;
  //   final ok = await showDialog<bool>(
  //     context: context,
  //     builder: (_) => AlertDialog(
  //       backgroundColor: Colors.white,
  //       surfaceTintColor: Colors.transparent,
  //       title: const Text('ご確認ください', style: TextStyle(color: Colors.black87)),
  //       content: const Column(
  //         mainAxisSize: MainAxisSize.min,
  //         crossAxisAlignment: CrossAxisAlignment.start,
  //         children: [
  //           Text(
  //             'Stripeを通じてチップを受け取る場合、Stripeの決済手数料として元金の2.4%が差し引かれます。（2.4%は標準の値であり、前後する可能性がございます。）',
  //             style: TextStyle(color: Colors.black87),
  //           ),
  //           SizedBox(height: 8),
  //           Text(
  //             'この手数料は運営手数料とは別に発生します。',
  //             style: TextStyle(color: Colors.black54),
  //           ),
  //         ],
  //       ),
  //       actionsPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
  //       actions: [
  //         TextButton(
  //           onPressed: () => Navigator.pop(context, false),
  //           child: const Text('キャンセル', style: TextStyle(color: Colors.black87)),
  //         ),
  //         FilledButton(
  //           style: FilledButton.styleFrom(
  //             backgroundColor: Colors.black,
  //             foregroundColor: Colors.white,
  //           ),
  //           onPressed: () => Navigator.pop(context, true),
  //           child: const Text('次へ'),
  //         ),
  //       ],
  //     ),
  //   );
  //   if (ok == true) {
  //     await _changePlan(tenantRef, _selectedPlan!);
  //   }
  // }

  Future<void> _changePlan(
    DocumentReference<Map<String, dynamic>> tenantRef,
    String newPlan,
  ) async {
    setState(() => _updatingPlan = true);
    try {
      final tSnap = await tenantRef.get();
      final tData = tSnap.data();

      final sub = (tData?['subscription'] as Map<String, dynamic>?) ?? {};
      final subId = sub['stripeSubscriptionId'] as String?;
      final status = (sub['status'] as String?) ?? '';

      if (subId == null || subId.isEmpty) {
        final res = await _functions
            .httpsCallable('createSubscriptionCheckout')
            .call(<String, dynamic>{
              'tenantId': widget.tenantId,
              'plan': newPlan,
            });
        final data = res.data as Map;
        final url = data['url'] as String?;
        if (url == null) {
          throw 'Checkout URLが取得できませんでした。';
        }
        await launchUrlString(url, webOnlyWindowName: '_self');
        return;
      }

      final applyWhen = (status == 'trialing')
          ? 'trial_now'
          : 'immediate_no_proration';

      final res = await _functions.httpsCallable('changeSubscriptionPlan').call(
        <String, dynamic>{
          'subscriptionId': subId,
          'newPlan': newPlan,
          'applyWhen': applyWhen,
        },
      );

      final data = res.data as Map;
      if (data['ok'] == true) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('プランを $newPlan に変更しました。')));
      } else {
        throw '変更APIの応答が不正です。';
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

  Future<void> _loadConnectedOnce() async {
    final ownerId = widget.ownerId;
    final tenantId = widget.tenantId;

    if (ownerId == null || tenantId == null) {
      if (mounted) setState(() => _connected = false);
      return;
    }

    try {
      final snap = await FirebaseFirestore.instance
          .collection(ownerId)
          .doc(tenantId)
          .get();

      if (!snap.exists) {
        if (mounted) setState(() => _connected = false);
        return;
      }

      final data = snap.data(); // Map<String, dynamic>?
      final status = data?['status']; // dynamic

      // 文字列 "active" を想定。大文字/空白ゆらぎにも軽く対応
      final isActive =
          (status is String) && status.trim().toLowerCase() == 'active';

      // もし階層に入っているなら例：
      // final subStatus = (data?['subscription'] as Map<String, dynamic>?)?['status'] as String?;
      // final isActive = (subStatus?.trim().toLowerCase() == 'active');

      if (mounted) setState(() => _connected = isActive);
    } catch (e) {
      if (mounted) setState(() => _connected = false);
    }
  }

  Future<void> _saveExtras(
    DocumentReference<Map<String, dynamic>> tenantRef,
  ) async {
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

  // -------- Build --------

  @override
  Widget build(BuildContext context) {
    if (_connected == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    // 黒基調のローカルテーマ（あなたの元のまま）
    final base = Theme.of(context);
    final themed = base.copyWith(
      textTheme: base.textTheme.apply(fontFamily: 'LINEseed'),
      primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'LINEseed'),
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
      inputDecorationTheme: base.inputDecorationTheme.copyWith(
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
      dialogTheme: base.dialogTheme.copyWith(
        contentTextStyle: base.textTheme.bodyMedium?.copyWith(
          fontFamily: 'LINEseed',
        ),
        titleTextStyle: base.textTheme.titleMedium?.copyWith(
          fontFamily: 'LINEseed',
          fontWeight: FontWeight.w600,
          color: Colors.black87,
        ),
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

    return _connected!
        ? Theme(
            data: themed,
            child: Padding(
              padding: const EdgeInsets.all(16),
              // ★ ここで ValueListenableBuilder を使う：タップしただけでは走らない
              child: ValueListenableBuilder<String>(
                valueListenable: _tenantIdVN,
                builder: (context, tid, _) {
                  final uid = FirebaseAuth.instance.currentUser?.uid;
                  if (uid == null) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  // ★ 選択された tid から毎回“そのときだけ”参照を作る
                  final tenantRef = FirebaseFirestore.instance
                      .collection(widget.ownerId!)
                      .doc(tid);

                  final publicThankRef = FirebaseFirestore.instance
                      .collection("publicThanks")
                      .doc(tid);

                  // ★ 正しい Stream（Doc の snapshots）を渡す
                  return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                    stream: tenantRef.snapshots(),
                    builder: (context, snap) {
                      if (snap.connectionState == ConnectionState.waiting) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      if (snap.hasError) {
                        return Center(child: Text('読み込みエラー: ${snap.error}'));
                      }

                      final data = snap.data?.data() ?? <String, dynamic>{};

                      final sub =
                          (data['subscription'] as Map?)
                              ?.cast<String, dynamic>() ??
                          {};
                      final currentPlan = (sub['plan'] as String?) ?? 'A';

                      final periodEndTs = sub['currentPeriodEnd'];
                      DateTime? periodEnd;
                      if (periodEndTs is Timestamp) {
                        periodEnd = periodEndTs.toDate();
                      }

                      final extras =
                          (sub['extras'] as Map?)?.cast<String, dynamic>() ??
                          {};
                      _selectedPlan ??= currentPlan;
                      if (_lineUrlCtrl.text.isEmpty) {
                        _lineUrlCtrl.text =
                            extras['lineOfficialUrl'] as String? ?? '';
                      }
                      if (_reviewUrlCtrl.text.isEmpty) {
                        _reviewUrlCtrl.text =
                            extras['googleReviewUrl'] as String? ?? '';
                      }

                      final store =
                          (data['storeDeduction'] as Map?)
                              ?.cast<String, dynamic>() ??
                          {};
                      if (_storePercentCtrl.text.isEmpty &&
                          store['percent'] != null) {
                        _storePercentCtrl.text = '${store['percent']}';
                      }
                      if (_storeFixedCtrl.text.isEmpty &&
                          store['fixed'] != null) {
                        _storeFixedCtrl.text = '${store['fixed']}';
                      }

                      final trialMap = (sub['trial'] as Map?)
                          ?.cast<String, dynamic>();
                      DateTime? trialStart;
                      DateTime? trialEnd;
                      if (trialMap != null) {
                        final tsStart = trialMap['trialStart'];
                        final tsEnd = trialMap['trialEnd'];
                        if (tsStart is Timestamp) {
                          trialStart = tsStart.toDate();
                        }
                        if (tsEnd is Timestamp) {
                          trialEnd = tsEnd.toDate();
                        }
                      }

                      return ListView(
                        children: [
                          // ===== ここから下はあなたの UI をそのまま（参照だけ tenantRef/publicThankRef を使う） =====
                          ownerIsMe
                              ? Column(
                                  children: [
                                    FilledButton.icon(
                                      style: FilledButton.styleFrom(
                                        backgroundColor: Colors.black,
                                        foregroundColor: Colors.white,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 16,
                                          vertical: 14,
                                        ),
                                      ),
                                      onPressed: () => Navigator.pushNamed(
                                        context,
                                        '/account',
                                      ),
                                      icon: const Icon(Icons.manage_accounts),
                                      label: const Text('アカウント情報を確認'),
                                    ),
                                    const SizedBox(height: 10),
                                    FilledButton.icon(
                                      style: FilledButton.styleFrom(
                                        backgroundColor: Colors.black,
                                        foregroundColor: Colors.white,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 16,
                                          vertical: 14,
                                        ),
                                      ),
                                      onPressed: () => Navigator.pushNamed(
                                        context,
                                        '/tenant',
                                      ),
                                      icon: const Icon(
                                        Icons.store_mall_directory_outlined,
                                      ),
                                      label: const Text('テナント情報を確認'),
                                    ),
                                  ],
                                )
                              : const SizedBox(height: 4),
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
                                          style: const TextStyle(
                                            color: Colors.black54,
                                          ),
                                        ),
                                    ],
                                  ),

                                  const SizedBox(height: 16),

                                  if (trialEnd != null)
                                    TrialProgressBar(
                                      trialStart: trialStart,
                                      trialEnd: trialEnd!,
                                      totalDays: 90,
                                      onTap: () {},
                                    ),

                                  const SizedBox(height: 12),

                                  Builder(
                                    builder: (_) {
                                      final effectivePickerValue = _changingPlan
                                          ? (_pendingPlan ?? currentPlan)
                                          : currentPlan;
                                      return Stack(
                                        children: [
                                          AbsorbPointer(
                                            absorbing: !_changingPlan,
                                            child: Opacity(
                                              opacity: _changingPlan
                                                  ? 1.0
                                                  : 0.5,
                                              child: PlanPicker(
                                                selected: effectivePickerValue,
                                                onChanged: _onPlanChanged,
                                              ),
                                            ),
                                          ),
                                        ],
                                      );
                                    },
                                  ),

                                  const SizedBox(height: 16),

                                  if (currentPlan == 'C') ...[
                                    buildCPerksSection(
                                      tenantRef: tenantRef,
                                      lineUrlCtrl: _lineUrlCtrl,
                                      reviewUrlCtrl: _reviewUrlCtrl,
                                      uploadingPhoto: _uploadingPhoto,
                                      uploadingVideo: _uploadingVideo,
                                      savingExtras: _savingExtras,
                                      thanksPhotoPreviewBytes:
                                          _thanksPhotoPreviewBytes,
                                      thanksPhotoUrlLocal: _thanksPhotoUrl,
                                      thanksVideoUrlLocal: _thanksVideoUrl,
                                      onSaveExtras: () =>
                                          _saveExtras(tenantRef),
                                      onPickPhoto: () => _pickAndUploadPhoto(
                                        tenantRef,
                                        publicThankRef,
                                      ),
                                      onDeletePhoto: () => _deleteThanksPhoto(
                                        tenantRef,
                                        publicThankRef,
                                      ),
                                      onPreviewVideo: showVideoPreview,
                                      primaryBtnStyle: primaryBtnStyle,
                                      thanksRef: publicThankRef,
                                    ),
                                  ],

                                  const SizedBox(height: 16),

                                  if (!_changingPlan) ...[
                                    Row(
                                      children: [
                                        Expanded(
                                          child: FilledButton.icon(
                                            style: primaryBtnStyle,
                                            onPressed: _updatingPlan
                                                ? null
                                                : _enterChangeMode,
                                            icon: const Icon(Icons.tune),
                                            label: const Text('サブスクのプランを変更'),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ] else ...[
                                    Row(
                                      children: [
                                        Expanded(
                                          child: FilledButton.icon(
                                            style: primaryBtnStyle,
                                            onPressed:
                                                (_updatingPlan ||
                                                    (_pendingPlan == null) ||
                                                    (_pendingPlan ==
                                                        currentPlan))
                                                ? null
                                                : () => _changePlan(
                                                    tenantRef,
                                                    _pendingPlan!,
                                                  ),
                                            icon: _updatingPlan
                                                ? const SizedBox(
                                                    width: 16,
                                                    height: 16,
                                                    child:
                                                        CircularProgressIndicator(
                                                          strokeWidth: 2,
                                                          color: Colors.white,
                                                        ),
                                                  )
                                                : const Icon(
                                                    Icons.check_circle,
                                                  ),
                                            label: Text(
                                              (_pendingPlan == currentPlan)
                                                  ? '変更なし'
                                                  : 'このプランに変更',
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        OutlinedButton.icon(
                                          style: outlinedBtnStyle,
                                          onPressed: _updatingPlan
                                              ? null
                                              : _cancelChangeMode,
                                          icon: const Icon(Icons.close),
                                          label: const Text('やめる'),
                                        ),
                                      ],
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),

                          const SizedBox(height: 24),
                          const Text(
                            "スタッフから差し引く金額を設定",
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: Colors.black87,
                              fontFamily: "LINEseed",
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
                                    style: TextStyle(
                                      color: Colors.black87,
                                      fontFamily: "LINEseed",
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  const SizedBox(height: 8),

                                  Builder(
                                    builder: (context) {
                                      final pending =
                                          (data['storeDeductionPending']
                                                  as Map?)
                                              ?.cast<String, dynamic>() ??
                                          const {};
                                      DateTime? eff;
                                      final ts = pending['effectiveFrom'];
                                      if (ts is Timestamp) eff = ts.toDate();
                                      eff ??= _firstDayOfNextMonth();
                                      final ym =
                                          '${eff.year}/${eff.month.toString()}';
                                      return Container(
                                        width: double.infinity,
                                        padding: const EdgeInsets.all(12),
                                        decoration: BoxDecoration(
                                          color: Colors.orange.withOpacity(
                                            0.16,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            10,
                                          ),
                                          border: Border.all(
                                            color: Colors.black12,
                                          ),
                                        ),
                                        child: Row(
                                          children: [
                                            const Icon(
                                              Icons.schedule,
                                              size: 18,
                                              color: Colors.orange,
                                            ),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: Text(
                                                'この変更は「今月分（$ym）の明細」から自動適用されます。',
                                                style: const TextStyle(
                                                  color: Colors.black87,
                                                  fontFamily: "LINEseed",
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
                                  const SizedBox(height: 7),

                                  StreamBuilder<
                                    DocumentSnapshot<Map<String, dynamic>>
                                  >(
                                    stream: tenantRef.snapshots(),
                                    builder: (context, snap2) {
                                      final d2 = snap2.data?.data() ?? {};
                                      final active =
                                          (d2['storeDeduction'] as Map?) ?? {};

                                      final activePercent =
                                          (active['percent'] ?? 0).toString();

                                      return Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              const Icon(
                                                Icons.info_outline,
                                                size: 18,
                                              ),
                                              const SizedBox(width: 6),
                                              Text(
                                                '現在：$activePercent%',
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.w600,
                                                  fontFamily: "LINEseed",
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 6),
                                          // Row(
                                          //   children: [
                                          //     const Icon(
                                          //       Icons.schedule,
                                          //       size: 18,
                                          //     ),
                                          //     const SizedBox(width: 6),
                                          //     Expanded(
                                          //       child: Text(
                                          //         (pending.isEmpty)
                                          //             ? '予約中の変更はありません'
                                          //             : '予約中：$pendingPercent%（${_fmtDate(pendingStart!)} から）',
                                          //         style: const TextStyle(
                                          //           fontFamily: "LINEseed",
                                          //         ),
                                          //       ),
                                          //     ),
                                          //     if (pending.isNotEmpty)
                                          //       TextButton.icon(
                                          //         onPressed: () async {
                                          //           await tenantRef.update({
                                          //             'storeDeductionPending':
                                          //                 FieldValue.delete(),
                                          //           });
                                          //           if (!context.mounted) {
                                          //             return;
                                          //           }
                                          //           ScaffoldMessenger.of(
                                          //             context,
                                          //           ).showSnackBar(
                                          //             const SnackBar(
                                          //               content: Text(
                                          //                 '変更予約を取り消しました',
                                          //               ),
                                          //             ),
                                          //           );
                                          //         },
                                          //         icon: const Icon(Icons.clear),
                                          //         label: const Text('変更予約を取消'),
                                          //       ),
                                          //   ],
                                          // ),
                                          const SizedBox(height: 8),
                                          const SizedBox(height: 12),
                                        ],
                                      );
                                    },
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
                                                color: Colors.white,
                                              ),
                                            )
                                          : const Icon(Icons.save),
                                      label: const Text('店舗が差し引く金額割合を保存'),
                                      style: FilledButton.styleFrom(
                                        backgroundColor: Colors.black,
                                        foregroundColor: Colors.white,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
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
                              fontFamily: "LINEseed",
                            ),
                          ),
                          const SizedBox(height: 8),

                          CardShell(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  StreamBuilder<QuerySnapshot>(
                                    stream: tenantRef
                                        .collection('invites')
                                        .where('status', isEqualTo: 'pending')
                                        .snapshots(),
                                    builder: (context, invSnap) {
                                      final invites =
                                          invSnap.data?.docs ?? const [];
                                      if (invSnap.connectionState ==
                                          ConnectionState.waiting) {
                                        return const Padding(
                                          padding: EdgeInsets.symmetric(
                                            vertical: 8,
                                          ),
                                          child: LinearProgressIndicator(),
                                        );
                                      }
                                      return Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          const Text(
                                            '承認待ちの招待',
                                            style: TextStyle(
                                              fontWeight: FontWeight.w600,
                                              color: Colors.black87,
                                              fontFamily: "LINEseed",
                                            ),
                                          ),
                                          const SizedBox(height: 6),
                                          if (invites.isEmpty)
                                            const Text(
                                              '承認待ちはありません',
                                              style: TextStyle(
                                                color: Colors.black54,
                                                fontFamily: "LINEseed",
                                              ),
                                            )
                                          else
                                            ...invites.map((d) {
                                              final m =
                                                  d.data()
                                                      as Map<String, dynamic>;
                                              final email =
                                                  (m['emailLower']
                                                      as String?) ??
                                                  '';
                                              final expTs = m['expiresAt'];
                                              final exp = expTs is Timestamp
                                                  ? expTs.toDate()
                                                  : null;
                                              return ListTile(
                                                dense: true,
                                                contentPadding: EdgeInsets.zero,
                                                leading: const Icon(
                                                  Icons.pending_actions,
                                                  color: Colors.orange,
                                                ),
                                                title: Text(
                                                  email,
                                                  style: const TextStyle(
                                                    color: Colors.black87,
                                                  ),
                                                ),
                                                subtitle: exp == null
                                                    ? null
                                                    : Text(
                                                        '有効期限: ${exp.year}/${exp.month.toString().padLeft(2, '0')}/${exp.day.toString().padLeft(2, '0')}',
                                                        style: const TextStyle(
                                                          color: Colors.black54,
                                                          fontFamily:
                                                              "LINEseed",
                                                        ),
                                                      ),
                                                trailing: Wrap(
                                                  spacing: 8,
                                                  children: [
                                                    TextButton.icon(
                                                      onPressed: () async {
                                                        await _functions
                                                            .httpsCallable(
                                                              'inviteTenantAdmin',
                                                            )
                                                            .call({
                                                              'tenantId': tid,
                                                              'email': email,
                                                            });
                                                        if (!mounted) return;
                                                        ScaffoldMessenger.of(
                                                          context,
                                                        ).showSnackBar(
                                                          const SnackBar(
                                                            content: Text(
                                                              '招待メールを再送しました',
                                                            ),
                                                          ),
                                                        );
                                                      },
                                                      icon: const Icon(
                                                        Icons.send,
                                                      ),
                                                      label: const Text('再送'),
                                                    ),
                                                    TextButton.icon(
                                                      onPressed: () async {
                                                        await _functions
                                                            .httpsCallable(
                                                              'cancelTenantAdminInvite',
                                                            )
                                                            .call({
                                                              'tenantId': tid,
                                                              'inviteId': d.id,
                                                            });
                                                        if (!mounted) return;
                                                        ScaffoldMessenger.of(
                                                          context,
                                                        ).showSnackBar(
                                                          const SnackBar(
                                                            content: Text(
                                                              '招待を取り消しました',
                                                            ),
                                                          ),
                                                        );
                                                      },
                                                      icon: const Icon(
                                                        Icons.close,
                                                      ),
                                                      label: const Text('取消'),
                                                    ),
                                                  ],
                                                ),
                                              );
                                            }),
                                          const Divider(height: 24),
                                        ],
                                      );
                                    },
                                  ),

                                  StreamBuilder<QuerySnapshot>(
                                    stream: tenantRef
                                        .collection('members')
                                        .snapshots(),
                                    builder: (context, memSnap) {
                                      final members = memSnap.data?.docs ?? [];
                                      final dataMap = data;

                                      if (memSnap.hasData &&
                                          members.isNotEmpty) {
                                        return AdminList(
                                          entries: members.map((m) {
                                            final md =
                                                m.data()
                                                    as Map<String, dynamic>;
                                            return AdminEntry(
                                              uid: widget.ownerId!,
                                              email:
                                                  (md['email'] as String?) ??
                                                  '',
                                              name:
                                                  (md['displayName']
                                                      as String?) ??
                                                  '',
                                              role:
                                                  (md['role'] as String?) ??
                                                  'admin',
                                            );
                                          }).toList(),
                                          onRemove: (uidToRemove) =>
                                              _removeAdmin(
                                                tenantRef,
                                                uidToRemove,
                                              ),
                                        );
                                      }

                                      final uids =
                                          (dataMap['memberUids'] as List?)
                                              ?.cast<String>() ??
                                          const <String>[];
                                      if (uids.isEmpty) {
                                        return const ListTile(
                                          title: Text(
                                            '管理者がいません',
                                            style: TextStyle(
                                              color: Colors.black87,
                                            ),
                                          ),
                                          subtitle: Text(
                                            '右上の追加ボタンから招待できます',
                                            style: TextStyle(
                                              color: Colors.black87,
                                            ),
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
                                        onRemove: (uidToRemove) => _removeAdmin(
                                          tenantRef,
                                          uidToRemove,
                                        ),
                                      );
                                    },
                                  ),

                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: TextButton.icon(
                                      onPressed: () =>
                                          _inviteAdminDialog(tenantRef),
                                      icon: const Icon(Icons.person_add_alt_1),
                                      label: const Text('管理者を追加（メール招待）'),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          Container(
                            margin: const EdgeInsets.symmetric(
                              vertical: 8,
                              horizontal: 16,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              border: Border.all(color: Colors.black26),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(999),
                              onTap: logout,
                              child: const Padding(
                                padding: EdgeInsets.symmetric(
                                  vertical: 12,
                                  horizontal: 20,
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.logout,
                                      color: Colors.black87,
                                      size: 18,
                                    ),
                                    SizedBox(width: 8),
                                    Text(
                                      'ログアウト',
                                      style: TextStyle(
                                        color: Colors.black87,
                                        fontWeight: FontWeight.w700,
                                        fontFamily: "LINEseed",
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  );
                },
              ),
            ),
          )
        : Scaffold(
            body: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text("新規登録を完了してください"),
                  const SizedBox(height: 30),
                  Container(
                    margin: const EdgeInsets.symmetric(
                      vertical: 8,
                      horizontal: 16,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border.all(color: Colors.black26),
                      borderRadius: BorderRadius.circular(999),
                    ),

                    child: InkWell(
                      borderRadius: BorderRadius.circular(999),
                      onTap: logout,
                      child: const Padding(
                        padding: EdgeInsets.symmetric(
                          vertical: 12,
                          horizontal: 20,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.logout, color: Colors.black87, size: 18),
                            SizedBox(width: 8),
                            Text(
                              'ログアウト',
                              style: TextStyle(
                                color: Colors.black87,
                                fontWeight: FontWeight.w700,
                                fontFamily: "LINEseed",
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
  }
}

// --- 小物 ---
class _InfoLine extends StatelessWidget {
  final String text;
  const _InfoLine(this.text);
  @override
  Widget build(BuildContext context) {
    return Row(
      children: const [
        Icon(Icons.info_outline, size: 16, color: Colors.black54),
        SizedBox(width: 6),
        Expanded(
          child: Text('', style: TextStyle(color: Colors.black54)),
        ),
      ],
    ).copyWithText(text);
  }
}

extension on Row {
  Row copyWithText(String t) {
    final children = List<Widget>.from(this.children);
    children[2] = Expanded(
      child: Text(t, style: const TextStyle(color: Colors.black54)),
    );
    return Row(children: children);
  }
}
