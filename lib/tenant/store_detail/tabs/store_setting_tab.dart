// tabs/settings_tab.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher_string.dart';

import 'package:yourpay/tenant/store_detail/card_shell.dart';

class StoreSettingsTab extends StatefulWidget {
  final String tenantId;
  const StoreSettingsTab({super.key, required this.tenantId});

  @override
  State<StoreSettingsTab> createState() => _StoreSettingsTabState();
}

class _StoreSettingsTabState extends State<StoreSettingsTab> {
  final _functions = FirebaseFunctions.instanceFor(region: 'us-central1');

  String? _selectedPlan; // 'A'|'B'|'C'
  final _lineUrlCtrl = TextEditingController();
  final _reviewUrlCtrl = TextEditingController();
  bool _updatingPlan = false;
  bool _savingExtras = false;

  final _storePercentCtrl = TextEditingController();
  final _storeFixedCtrl = TextEditingController();
  bool _savingStoreCut = false;

  @override
  void dispose() {
    _lineUrlCtrl.dispose();
    _reviewUrlCtrl.dispose();
    _storePercentCtrl.dispose();
    _storeFixedCtrl.dispose();

    super.dispose();
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
      await tenantRef.set({
        'storeDeduction': {'percent': p, 'fixed': f},
      }, SetOptions(merge: true));

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('店舗控除を保存しました')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('店舗控除の保存に失敗: $e')));
    } finally {
      if (mounted) setState(() => _savingStoreCut = false);
    }
  }

  Future<void> _changePlan(DocumentReference tenantRef, String plan) async {
    setState(() => _updatingPlan = true);
    try {
      final res = await _functions
          .httpsCallable('createSubscriptionCheckout')
          .call({'tenantId': widget.tenantId, 'plan': plan});
      final url = (res.data as Map)['url'] as String?;
      if (url != null && url.isNotEmpty) {
        await launchUrlString(url, mode: LaunchMode.externalApplication);
      } else {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('プラン変更を受け付けました')));
        }
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
      await launchUrlString(url, mode: LaunchMode.externalApplication);
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
        title: const Text('管理者を招待', style: TextStyle(color: Colors.black87)),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(labelText: 'メールアドレス'),
          keyboardType: TextInputType.emailAddress,
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
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
        title: const Text('管理者を削除'),
        content: Text('このメンバー（$uid）を管理者から外しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
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

    return Padding(
      padding: const EdgeInsets.all(16),
      child: StreamBuilder<DocumentSnapshot>(
        stream: tenantRef.snapshots(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final data = snap.data?.data() as Map<String, dynamic>? ?? {};
          final sub =
              (data['subscription'] as Map?)?.cast<String, dynamic>() ?? {};
          final currentPlan = (sub['plan'] as String?) ?? 'A';
          final status = (sub['status'] as String?) ?? 'inactive';
          final pct = (sub['feePercent'] as num?)?.toInt();
          final periodEndTs = sub['currentPeriodEnd'];
          DateTime? periodEnd;
          if (periodEndTs is Timestamp) periodEnd = periodEndTs.toDate();

          final extras = (sub['extras'] as Map?)?.cast<String, dynamic>() ?? {};
          _selectedPlan ??= currentPlan;
          if (_lineUrlCtrl.text.isEmpty)
            _lineUrlCtrl.text = extras['lineOfficialUrl'] as String? ?? '';
          if (_reviewUrlCtrl.text.isEmpty)
            _reviewUrlCtrl.text = extras['googleReviewUrl'] as String? ?? '';
          // ▼ 初期反映（店舗控除）
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
              const Text(
                'サブスク',
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
                            'プラン $currentPlan  •  手数料 ${pct ?? (_selectedPlan == 'A'
                                    ? 20
                                    : _selectedPlan == 'B'
                                    ? 15
                                    : 10)}%  •  ステータス: $status',
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
                            label: const Text('特典リンクを保存'),
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
                                  : () =>
                                        _changePlan(tenantRef, _selectedPlan!),
                              icon: _updatingPlan
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Icon(Icons.autorenew),
                              label: Text(
                                currentPlan == _selectedPlan
                                    ? '再設定/再購読'
                                    : 'このプランに変更',
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          OutlinedButton.icon(
                            style: outlinedBtnStyle,
                            onPressed: _openCustomerPortal,
                            icon: const Icon(Icons.credit_card),
                            label: const Text('支払い情報を管理'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                '店舗の控除・手数料',
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
                        'チップから店舗が差し引く金額を設定します（スタッフ受取分の計算に使用）。',
                        style: TextStyle(color: Colors.black87),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          // ％
                          Expanded(
                            child: TextField(
                              controller: _storePercentCtrl,
                              decoration: const InputDecoration(
                                labelText: '控除（％）',
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
                          const SizedBox(width: 12),
                          // 固定額（円）
                          Expanded(
                            child: TextField(
                              controller: _storeFixedCtrl,
                              decoration: const InputDecoration(
                                labelText: '控除（固定額, 円）',
                                hintText: '例: 50',
                                suffixText: '円',
                              ),
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
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
                                    color: Colors.white,
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
              const SizedBox(height: 12),
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
                              title: Text('管理者がいません'),
                              subtitle: Text('右上の追加ボタンから招待できます'),
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
    );
  }
}
