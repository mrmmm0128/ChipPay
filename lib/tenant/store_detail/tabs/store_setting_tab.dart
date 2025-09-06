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
import 'package:yourpay/tenant/widget/trial_progress_bar.dart';

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
  DateTime? _effectiveFromLocal; // 予約の適用開始（未指定なら翌月1日 0:00）
  String _fmtDate(DateTime d) =>
      '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  String? _selectedPlan;
  bool _changingPlan = false;
  String? _pendingPlan;
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
  Uint8List? _thanksPhotoPreviewBytes;

  @override
  void initState() {
    super.initState();
    _effectiveFromLocal = _firstDayOfNextMonth();
  }

  @override
  void dispose() {
    _lineUrlCtrl.dispose();
    _reviewUrlCtrl.dispose();
    _storePercentCtrl.dispose();
    _storeFixedCtrl.dispose();
    super.dispose();
  }

  void _enterChangeMode() {
    setState(() {
      _changingPlan = true;
      _pendingPlan = _selectedPlan; // 現在値から開始
    });
  }

  void _cancelChangeMode() {
    setState(() {
      _changingPlan = false;
      _pendingPlan = null;
    });
  }

  // state 内にメソッドを1つ用意
  void _onPlanChanged(String v) {
    if (!_changingPlan) return; // ロック中は無視
    setState(() => _pendingPlan = v); // 変更モード時のみ反映
  }

  Future<void> _applyPlanChange(DocumentReference tenantRef) async {
    if (_pendingPlan == null || _pendingPlan == _selectedPlan) return;
    // 既存の処理を利用する場合は、選択値を噛ませてから呼ぶ
    setState(
      () => _selectedPlan = _pendingPlan,
    ); // ← 既存関数が _selectedPlan を読む想定なら
    await _showStripeFeeNoticeAndProceed(
      tenantRef,
    ); // 引数に plan を渡せるなら { plan: _pendingPlan! } でOK
    // 成功後はモード終了（画面リロードで currentPlan が更新される前提）
    if (mounted) {
      setState(() {
        _changingPlan = false;
        // _pendingPlan はクリア（currentPlan の最新化は上位の Stream/再読込に任せる）
        _pendingPlan = null;
      });
    }
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

  Future<void> _showInvoicesDialog(BuildContext context) async {
    // まだ読み込んでいなければ先に取得
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

                // created は「秒」想定 / Firestore Timestamp 両対応
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
                          sbSet(() {}); // ダイアログ内だけ再描画
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

    // 適用開始日時（未指定なら翌月1日）
    var eff = _effectiveFromLocal ?? _firstDayOfNextMonth();

    // もし過去が選ばれたら「今」に寄せる（必要なければ削除）
    final now = DateTime.now();
    if (eff.isBefore(now)) {
      eff = now;
    }

    setState(() => _savingStoreCut = true);
    try {
      await tenantRef.set({
        'storeDeductionPending': {
          'percent': p,
          'fixed': f,
          'effectiveFrom': Timestamp.fromDate(eff),
        },
      }, SetOptions(merge: true));

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('店舗控除を保存しました（${_fmtDate(eff)} から適用）')),
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

  Future<void> _changePlan(DocumentReference tenantRef, String newPlan) async {
    setState(() => _updatingPlan = true);
    try {
      // 現在の購読情報を取得
      final tSnap = await tenantRef.get();
      final tData = tSnap.data() as Map<String, dynamic>?;

      final sub = (tData?['subscription'] as Map<String, dynamic>?) ?? {};
      final subId = sub['stripeSubscriptionId'] as String?;
      final status =
          (sub['status'] as String?) ?? ''; // 'trialing' / 'active' など

      if (subId == null || subId.isEmpty) {
        // まだサブスクが無い → 初回登録（90日トライアル開始）。Checkoutへ遷移。
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

      // サブスクあり → プラン差し替え（トライアルならtrial維持、それ以外は差額課金なしで次回から反映）
      final applyWhen = (status == 'trialing')
          ? 'trial_now'
          : 'immediate_no_proration';

      final res = await _functions.httpsCallable('changeSubscriptionPlan').call(
        <String, dynamic>{
          'subscriptionId': subId,
          'newPlan': newPlan, // "A" | "B" | "C"
          'applyWhen': applyWhen, // バックエンドの拡張版に対応
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

    final uid = FirebaseAuth.instance.currentUser?.uid;

    final tenantRef = FirebaseFirestore.instance
        .collection(uid!)
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

            // ここを修正：subscription.trial から取り出す
            final trialMap = (sub['trial'] as Map?)?.cast<String, dynamic>();
            DateTime? trialStart;
            DateTime? trialEnd;
            if (trialMap != null) {
              final tsStart = trialMap['trialStart'];
              final tsEnd = trialMap['trialEnd'];
              if (tsStart is Timestamp) trialStart = tsStart.toDate();
              if (tsEnd is Timestamp) trialEnd = tsEnd.toDate();
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
                        // ── 上段：現在のステータス ────────────────────────────
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

                        // ── トライアル進捗（必要に応じてnullガード調整） ───────────
                        TrialProgressBar(
                          trialStart: trialStart,
                          trialEnd: trialEnd!, // 非null前提のまま踏襲
                          totalDays: 90,
                          onTap: () {},
                        ),

                        const SizedBox(height: 12),

                        // ── プラン選択（「サブスクを変更」を押すまで操作不可） ─────
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
                                    opacity: _changingPlan ? 1.0 : 0.5,
                                    child: PlanPicker(
                                      selected: effectivePickerValue,
                                      onChanged: _onPlanChanged, // 常に渡す（中で無視する）
                                    ),
                                  ),
                                ),
                                if (!_changingPlan)
                                  Positioned.fill(
                                    child: IgnorePointer(
                                      child: Container(
                                        alignment: Alignment.center,
                                        child: const Text(
                                          '「サブスクを変更」を押すと選べます',
                                          style: TextStyle(
                                            color: Colors.black54,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            );
                          },
                        ),

                        const SizedBox(height: 16),

                        // ── Cプラン特典（現在の契約がCのときだけ表示） ─────────────
                        if (currentPlan == 'C') ...[
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
                              label: const Text('特典を保存'),
                            ),
                          ),
                          // ===== 感謝メディアここまで =====
                        ],

                        const SizedBox(height: 16),

                        // ── 操作ボタン群 ────────────────────────────────
                        if (!_changingPlan) ...[
                          // 通常時：変更モードへ
                          Row(
                            children: [
                              Expanded(
                                child: FilledButton.icon(
                                  style: primaryBtnStyle,
                                  onPressed: _updatingPlan
                                      ? null
                                      : _enterChangeMode,
                                  icon: const Icon(Icons.tune),
                                  label: const Text('サブスクを変更'),
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
                        ] else ...[
                          // 変更モード：適用／キャンセル
                          Row(
                            children: [
                              Expanded(
                                child: FilledButton.icon(
                                  style: primaryBtnStyle,
                                  onPressed:
                                      (_updatingPlan ||
                                          (_pendingPlan == null) ||
                                          (_pendingPlan == currentPlan))
                                      ? null
                                      : () => _applyPlanChange(tenantRef),
                                  icon: _updatingPlan
                                      ? const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white,
                                          ),
                                        )
                                      : const Icon(Icons.check_circle),
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
                                color: Colors.orange.withOpacity(0.16),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: Colors.black12),
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
                        const SizedBox(height: 7),

                        StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                          stream: tenantRef.snapshots(),
                          builder: (context, snap) {
                            final data = snap.data?.data() ?? {};

                            final active =
                                (data['storeDeduction'] as Map?) ?? {};
                            final pending =
                                (data['storeDeductionPending'] as Map?) ?? {};

                            final activePercent = (active['percent'] ?? 0)
                                .toString();

                            final pendingPercent = (pending['percent'] ?? 0)
                                .toString();

                            final pendingStart =
                                (pending['effectiveFrom'] is Timestamp)
                                ? (pending['effectiveFrom'] as Timestamp)
                                      .toDate()
                                : null;

                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // 現在の値
                                Row(
                                  children: [
                                    const Icon(Icons.info_outline, size: 18),
                                    const SizedBox(width: 6),
                                    Text(
                                      '現在：$activePercent%',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),

                                // 予約中
                                Row(
                                  children: [
                                    const Icon(Icons.schedule, size: 18),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        (pending.isEmpty)
                                            ? '予約中の変更はありません'
                                            : '予約中：$pendingPercent%（${_fmtDate(pendingStart!)} から）',
                                      ),
                                    ),
                                    if (pending.isNotEmpty)
                                      TextButton.icon(
                                        onPressed: () async {
                                          await tenantRef.update({
                                            'storeDeductionPending':
                                                FieldValue.delete(),
                                          });
                                          if (!context.mounted) return;
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            const SnackBar(
                                              content: Text('変更予約を取り消しました'),
                                            ),
                                          );
                                        },
                                        icon: const Icon(Icons.clear),
                                        label: const Text('変更予約を取消'),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 8),

                                // // 適用開始日時ピッカー
                                // Row(
                                //   children: [
                                //     const Text('適用開始：'),
                                //     const SizedBox(width: 8),
                                //     OutlinedButton.icon(
                                //       onPressed: () async {
                                //         // 日付選択
                                //         final now = DateTime.now();
                                //         final init =
                                //             _effectiveFromLocal ??
                                //             _firstDayOfNextMonth();
                                //         final pickedDate = await showDatePicker(
                                //           context: context,
                                //           initialDate: init.isAfter(now)
                                //               ? init
                                //               : now,
                                //           firstDate: now.subtract(
                                //             const Duration(days: 0),
                                //           ),
                                //           lastDate: DateTime(now.year + 3),
                                //         );
                                //         if (pickedDate == null) return;

                                //         // 時刻選択（任意。不要ならこのブロックを削って 00:00 固定でもOK）
                                //         final pickedTime = await showTimePicker(
                                //           context: context,
                                //           initialTime: const TimeOfDay(
                                //             hour: 0,
                                //             minute: 0,
                                //           ),
                                //         );

                                //         final eff = DateTime(
                                //           pickedDate.year,
                                //           pickedDate.month,
                                //           pickedDate.day,
                                //           pickedTime?.hour ?? 0,
                                //           pickedTime?.minute ?? 0,
                                //         );
                                //         setState(
                                //           () => _effectiveFromLocal = eff,
                                //         );
                                //       },
                                //       icon: const Icon(Icons.calendar_today),
                                //       label: Text(
                                //         _effectiveFromLocal == null
                                //             ? '未設定'
                                //             : _fmtDate(_effectiveFromLocal!),
                                //       ),
                                //     ),
                                //   ],
                                // ),
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
                                      color: Colors.white, // 黒ボタン上なので白
                                    ),
                                  )
                                : const Icon(Icons.save),
                            label: const Text('店舗が差し引く金額割合を保存'),
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
                  'サブスクリプション請求履歴',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 8),
                CardShell(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: OutlinedButton.icon(
                        onPressed: _loadingInvoices
                            ? null
                            : () => _showInvoicesDialog(context),
                        icon: const Icon(Icons.receipt_long),
                        label: const Text('請求履歴を確認'),
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 16),
                // 既存: 管理者一覧タイトル
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
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // ① 承認待ちの招待一覧
                        StreamBuilder<QuerySnapshot>(
                          stream: tenantRef
                              .collection('invites')
                              .where('status', isEqualTo: 'pending')
                              .snapshots(),
                          builder: (context, invSnap) {
                            final invites = invSnap.data?.docs ?? const [];
                            if (invSnap.connectionState ==
                                ConnectionState.waiting) {
                              return const Padding(
                                padding: EdgeInsets.symmetric(vertical: 8),
                                child: LinearProgressIndicator(),
                              );
                            }
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  '承認待ちの招待',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    color: Colors.black87,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                if (invites.isEmpty)
                                  const Text(
                                    '承認待ちはありません',
                                    style: TextStyle(color: Colors.black54),
                                  )
                                else
                                  ...invites.map((d) {
                                    final m = d.data() as Map<String, dynamic>;
                                    final email =
                                        (m['emailLower'] as String?) ?? '';
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
                                              ),
                                            ),
                                      trailing: Wrap(
                                        spacing: 8,
                                        children: [
                                          TextButton.icon(
                                            onPressed: () async {
                                              // 再送（同じメールで再度invitation → バックエンド側でトークン更新＆送信）
                                              await _functions
                                                  .httpsCallable(
                                                    'inviteTenantAdmin',
                                                  )
                                                  .call({
                                                    'tenantId': widget.tenantId,
                                                    'email': email,
                                                  });
                                              if (!mounted) return;
                                              ScaffoldMessenger.of(
                                                context,
                                              ).showSnackBar(
                                                const SnackBar(
                                                  content: Text('招待メールを再送しました'),
                                                ),
                                              );
                                            },
                                            icon: const Icon(Icons.send),
                                            label: const Text('再送'),
                                          ),
                                          TextButton.icon(
                                            onPressed: () async {
                                              await _functions
                                                  .httpsCallable(
                                                    'cancelTenantAdminInvite',
                                                  )
                                                  .call({
                                                    'tenantId': widget.tenantId,
                                                    'inviteId': d.id,
                                                  });
                                              if (!mounted) return;
                                              ScaffoldMessenger.of(
                                                context,
                                              ).showSnackBar(
                                                const SnackBar(
                                                  content: Text('招待を取り消しました'),
                                                ),
                                              );
                                            },
                                            icon: const Icon(Icons.close),
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

                        // ② 承認済みの管理者一覧（あなたの既存コードそのまま）
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

                            // フォールバック（memberUids をまだ使う場合）
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
