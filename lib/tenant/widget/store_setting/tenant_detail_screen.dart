import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:url_launcher/url_launcher_string.dart';

class tenantDetailScreen extends StatefulWidget {
  const tenantDetailScreen({super.key});
  @override
  State<tenantDetailScreen> createState() => _AccountDetailScreenState();
}

class _AccountDetailScreenState extends State<tenantDetailScreen> {
  final _tenantName = TextEditingController();

  bool _saving = false;
  bool _loadingPayouts = false;
  List<Map<String, dynamic>> _payouts = [];
  Map<String, dynamic>? _payoutDetail; // 直近選択の詳細

  // テナント解決/ポータル起動用
  String? _tenantId; // ルート引数 or 自動推定
  bool _openingCustomerPortal = false;
  bool _openingConnectPortal = false;
  bool _loadingUpcoming = false; // ← 追加：請求予定（upcoming）読み込み中
  Map<String, dynamic>? _upcomingInvoice;

  // 請求読み込み用
  List<Map<String, dynamic>> _invoices = [];
  bool _loadingInvoices = false;
  List<Map<String, dynamic>> _oneTime = []; // 初期費用(一括決済)だけ
  List<Map<String, dynamic>> _history = []; // 時系列まとめ（サーバーでソート済）

  bool _cancelingSub = false;

  final _agencyCodeCtrl = TextEditingController();
  bool _linkingAgency = false;
  Map<String, dynamic>? _agency; // {code, uid, name, linkedAt ...} を想定

  bool _isZeroDecimal(String c) {
    const zero = {'JPY', 'KRW', 'VND'};
    return zero.contains(c.toUpperCase());
  }

  String _money(num v, String currency) {
    final z = _isZeroDecimal(currency);
    final amt = z ? v : v / 100;
    return amt.toStringAsFixed(z ? 0 : 2);
  }

  Future<void> _loadPayouts() async {
    final tid = _tenantId;
    if (tid == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('店舗が見つかりません')));
      return;
    }
    setState(() => _loadingPayouts = true);
    try {
      await FirebaseAuth.instance.currentUser?.getIdToken(true);
      final fn = FirebaseFunctions.instanceFor(
        region: 'us-central1',
      ).httpsCallable('listConnectPayouts');
      final res = await fn.call({'tenantId': tid, 'limit': 20});
      final map = (res.data as Map?) ?? const {};
      _payouts = (map['payouts'] as List? ?? [])
          .cast<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
      if (mounted) setState(() {});
      await _showPayoutsDialog(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('入金の取得に失敗: $e')));
      }
    } finally {
      if (mounted) setState(() => _loadingPayouts = false);
    }
  }

  Future<Map<String, dynamic>?> _fetchPayoutDetail(String payoutId) async {
    final tid = _tenantId;
    if (tid == null) return null;
    try {
      final fn = FirebaseFunctions.instanceFor(
        region: 'us-central1',
      ).httpsCallable('getConnectPayoutDetails');
      final res = await fn.call({'tenantId': tid, 'payoutId': payoutId});
      return (res.data as Map?)?.cast<String, dynamic>();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('入金詳細の取得に失敗: $e')));
      }
      return null;
    }
  }

  Future<void> _showPayoutsDialog(BuildContext context) async {
    if (_payouts.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('入金履歴はまだありません')));
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, sbSet) {
          DateTime _toDate(dynamic v) => DateTime.fromMillisecondsSinceEpoch(
            ((v as num?) ?? 0).toInt() * 1000,
          );
          String _ymd(DateTime d) =>
              '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';

          Widget _row(Map<String, dynamic> p) {
            final cur = (p['currency'] ?? 'JPY').toString().toUpperCase();
            final amt = (p['amount'] as num?) ?? 0;
            final status = (p['status'] ?? '').toString();
            final arrival = p['arrival_date'];
            final created = p['created'];

            return ListTile(
              leading: const Icon(Icons.account_balance_wallet_outlined),
              title: Text('入金: ${_money(amt, cur)} $cur'),
              subtitle: Text(
                '作成: ${_ymd(_toDate(created))}  /  着金予定: ${_ymd(_toDate(arrival))}  /  状態: $status',
                style: const TextStyle(color: Colors.black54),
              ),
              trailing: TextButton(
                child: const Text('詳細'),
                onPressed: () async {
                  final d = await _fetchPayoutDetail((p['id'] as String));
                  if (d == null) return;
                  _payoutDetail = d;
                  if (!ctx.mounted) return;
                  await showDialog<void>(
                    context: ctx,
                    builder: (ctx2) {
                      final pay =
                          (_payoutDetail?['payout'] as Map?)
                              ?.cast<String, dynamic>() ??
                          {};
                      final sum =
                          (_payoutDetail?['summary'] as Map?)
                              ?.cast<String, dynamic>() ??
                          {};
                      final lines = ((_payoutDetail?['lines'] as List?) ?? [])
                          .cast<Map>()
                          .map((e) => e.cast<String, dynamic>())
                          .toList();
                      final c = (sum['currency'] ?? pay['currency'] ?? 'JPY')
                          .toString()
                          .toUpperCase();
                      return AlertDialog(
                        title: const Text('入金の詳細'),
                        content: SizedBox(
                          width: 700,
                          height: 500,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '合計(ネット): ${_money((sum['net'] ?? pay['amount'] ?? 0) as num, c)} $c',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '総額: ${_money((sum['gross'] ?? 0) as num, c)} $c   手数料: ${_money((sum['fees'] ?? 0) as num, c)} $c',
                                style: const TextStyle(color: Colors.black87),
                              ),
                              const SizedBox(height: 12),
                              const Divider(height: 1),
                              const SizedBox(height: 8),
                              Expanded(
                                child: lines.isEmpty
                                    ? const Center(child: Text('明細がありません'))
                                    : ListView.separated(
                                        itemCount: lines.length,
                                        separatorBuilder: (_, __) =>
                                            const Divider(height: 1),
                                        itemBuilder: (_, i) {
                                          final ln = lines[i];
                                          final t = (ln['type'] ?? '')
                                              .toString();
                                          final a = (ln['amount'] ?? 0) as num;
                                          final f = (ln['fee'] ?? 0) as num;
                                          final n = (ln['net'] ?? 0) as num;
                                          final desc =
                                              (ln['description'] ??
                                                      ln['id'] ??
                                                      '')
                                                  .toString();
                                          return ListTile(
                                            dense: true,
                                            leading: const Icon(
                                              Icons.list_alt_outlined,
                                            ),
                                            title: Text(
                                              desc.isEmpty ? t : desc,
                                            ),
                                            subtitle: Text(
                                              '種類: $t / 手数料: ${_money(f, c)} $c',
                                              style: const TextStyle(
                                                color: Colors.black54,
                                              ),
                                            ),
                                            trailing: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.end,
                                              children: [
                                                Text('金額: ${_money(a, c)} $c'),
                                                Text(
                                                  '純額: ${_money(n, c)} $c',
                                                  style: const TextStyle(
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          );
                                        },
                                      ),
                              ),
                            ],
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx2),
                            child: const Text('閉じる'),
                          ),
                        ],
                      );
                    },
                  );
                },
              ),
            );
          }

          return AlertDialog(
            title: const Text('入金履歴'),
            content: SizedBox(
              width: 700,
              height: 520,
              child: _payouts.isEmpty
                  ? const Center(child: Text('入金履歴はまだありません'))
                  : ListView.separated(
                      itemCount: _payouts.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) => _row(_payouts[i]),
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('閉じる'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _cancelSubscription() async {
    final tid = _tenantId;
    if (tid == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('店舗が見つかりません')));
      return;
    }

    // 同意ダイアログ（チェック必須）
    bool agreed = false;
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        bool agreed = false; // ダイアログ内の状態
        return StatefulBuilder(
          builder: (ctx, setSB) {
            return AlertDialog(
              title: const Text('サブスクリプションを解約しますか？'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('解約すると、トライアル期間であっても再度トライアルを再開することはできません。'),
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('上記に同意します'),
                    value: agreed,
                    onChanged: (v) => setSB(() => agreed = v ?? false),
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('キャンセル'),
                ),
                FilledButton(
                  onPressed: agreed ? () => Navigator.pop(ctx, true) : null,
                  child: const Text('解約する'),
                ),
              ],
            );
          },
        );
      },
    );

    if (ok != true) return;

    setState(() => _cancelingSub = true);
    try {
      await FirebaseAuth.instance.currentUser?.getIdToken(true);
      final fn = FirebaseFunctions.instanceFor(
        region: 'us-central1',
      ).httpsCallable('cancelSubscription');
      final res = await fn.call({'agreeNoTrialResume': true});

      final data = (res.data as Map?) ?? const {};
      final status = (data['status'] ?? '').toString();

      String msg;
      switch (status) {
        case 'no_subscription':
          msg = '現在アクティブなサブスクリプションはありません。';
          break;
        case 'canceled_now':
          msg = '解約しました（トライアル中のため即時反映）。';
          break;
        case 'cancel_at_period_end':
          final cancelAt = data['cancel_at'];
          if (cancelAt is int) {
            final dt = DateTime.fromMillisecondsSinceEpoch(cancelAt * 1000);
            msg = '解約を受け付けました。次回更新（${_fmtYMD(dt)}）で停止します。';
          } else {
            msg = '解約を受け付けました。次回更新で停止します。';
          }
          break;
        default:
          msg = '解約リクエストを送信しました。';
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } on FirebaseFunctionsException catch (e) {
      final code = e.code;
      final friendly = switch (code) {
        'unauthenticated' => 'ログイン情報が無効です。再ログインしてお試しください。',
        'invalid-argument' => '必要な情報が不足しています（tenantId）。',
        'failed-precondition' => '「トライアル再開不可」に同意してください。',
        'permission-denied' => '権限がありません。',
        _ => '解約に失敗: ${e.code} ${e.message ?? ''}',
      };
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(friendly)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('エラー: $e')));
      }
    } finally {
      if (mounted) setState(() => _cancelingSub = false);
    }
  }

  String _fmtYMD(DateTime d) =>
      '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';

  @override
  void initState() {
    super.initState();
    // 画面遷移の引数から tenantId が来ていれば採用
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final args = ModalRoute.of(context)?.settings.arguments;
      if (args is Map &&
          args['tenantId'] is String &&
          (args['tenantId'] as String).isNotEmpty) {
        _tenantId = args['tenantId'] as String;
        setState(() {});
        _loadTenantName();
        _loadAgencyLink(); // 代理店情報も読む
      } else {
        _resolveFirstTenant(); // 自動推定 → 読み込み
      }
    });
  }

  Future<String?> _resolveStripeCustomerId() async {
    final user = FirebaseAuth.instance.currentUser;
    final tid = _tenantId;
    if (user == null || tid == null) return null;
    try {
      final doc = await FirebaseFirestore.instance
          .collection(user.uid)
          .doc(tid)
          .get();
      final d = doc.data();
      if (d == null) return null;
      // subscription.stripeCustomerId 優先
      final sub = (d['subscription'] as Map?)?.cast<String, dynamic>() ?? {};
      final cid = (sub['stripeCustomerId'] as String?)?.trim();
      if (cid != null && cid.isNotEmpty) return cid;

      // 予備: tenantIndex を見にいく場合（必要なら）
      // final idx = await FirebaseFirestore.instance
      //   .collection('tenantIndex').doc(tid).get();
      // final cid2 = (idx.data()?['stripeCustomerId'] as String?)?.trim();
      // if (cid2 != null && cid2.isNotEmpty) return cid2;

      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _fetchUpcomingInvoice() async {
    final tid = _tenantId;
    if (tid == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('店舗が見つかりません')));
      return;
    }

    setState(() => _loadingUpcoming = true);
    try {
      // customerId を Firestore から解決
      final customerId = await _resolveStripeCustomerId();
      if (customerId == null || customerId.isEmpty) {
        throw 'StripeのカスタマーIDを確認できませんでした';
      }

      await FirebaseAuth.instance.currentUser?.getIdToken(true);

      // ← ここを 'getUpcomingInvoiceByCustomer' に変更

      final fn = FirebaseFunctions.instanceFor(
        region: 'us-central1',
      ).httpsCallable('getUpcomingInvoiceByCustomer');

      // subscriptionId は省略（関数側でアクティブを自動解決）
      final res = await fn.call({'customerId': customerId});
      final data = (res.data as Map?)?.cast<String, dynamic>();

      if (data == null) {
        throw '請求予定が見つかりませんでした';
      }

      // upcoming が無い（invoice_upcoming_none）ケース
      if (data['ok'] == true && data['none'] == true) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('現在、次回の請求予定はありません')));
        }
        return;
      }

      // 正常ケース
      _upcomingInvoice = data;
      if (!mounted) return;
      await _showUpcomingDialog(context);
    } on FirebaseFunctionsException catch (e) {
      final msg = switch (e.code) {
        'unauthenticated' => 'ログイン情報が無効です。再ログインしてお試しください。',
        'permission-denied' => '権限がありません（この顧客にアクセスできません）。',
        'invalid-argument' => '不正なパラメータです。',
        _ => '請求予定の取得に失敗: ${e.code} ${e.message ?? ''}',
      };
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(msg)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('エラー: $e')));
      }
    } finally {
      if (mounted) setState(() => _loadingUpcoming = false);
    }
  }

  Future<void> _showUpcomingDialog(BuildContext context) async {
    final up = _upcomingInvoice ?? {};
    DateTime _toDate(dynamic raw) {
      if (raw is int) return DateTime.fromMillisecondsSinceEpoch(raw * 1000);
      if (raw is double)
        return DateTime.fromMillisecondsSinceEpoch((raw * 1000).round());
      if (raw is Timestamp) return raw.toDate();
      return DateTime.now();
    }

    String _fmtYMD(DateTime d) =>
        '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';

    final currency = (up['currency'] ?? 'JPY').toString().toUpperCase();
    final amountDue = ((up['amount_due'] ?? up['amountDue'] ?? 0) as num)
        .toDouble(); // CFによってキー差異を吸収
    final subtotal = ((up['subtotal'] ?? 0) as num).toDouble();
    final tax = ((up['tax'] ?? 0) as num).toDouble();
    final total = ((up['total'] ?? amountDue) as num).toDouble();

    final nextAt = up['next_payment_attempt'] ?? up['nextPaymentAttempt'];
    final periodStart = up['period_start'] ?? up['periodStart'];
    final periodEnd = up['period_end'] ?? up['periodEnd'];

    final lines = ((up['lines'] ?? const []) as List)
        .cast<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();

    String _money(num v) => (v / 100).toStringAsFixed(2); // Stripeは最小通貨単位

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          title: const Text('次回の請求予定'),
          content: SizedBox(
            width: 700,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // サマリ
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (nextAt != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                '次回決済予定日: ${_fmtYMD(_toDate(nextAt))}',
                                style: const TextStyle(color: Colors.black87),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '小計: ${_money(subtotal)} $currency',
                          style: const TextStyle(color: Colors.black87),
                        ),
                        Text(
                          '税額: ${_money(tax)} $currency',
                          style: const TextStyle(color: Colors.black87),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '合計: ${_money(total)} $currency',
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Divider(height: 1),
                const SizedBox(height: 8),
                // 明細
                Flexible(
                  child: lines.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.all(8.0),
                          child: Text('明細はありません'),
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          itemCount: lines.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final ln = lines[i];
                            final desc =
                                (ln['description'] ??
                                        ln['planNickname'] ??
                                        ln['priceNickname'] ??
                                        '')
                                    .toString();
                            final qty = (ln['quantity'] ?? 1) as num;
                            final unit =
                                ((ln['unit_amount'] ??
                                            ln['unitAmount'] ??
                                            ln['price']?['unit_amount']) ??
                                        0)
                                    as num;
                            final lineTotal = ((ln['amount'] ?? 0) as num)
                                .toDouble();
                            final isProration = (ln['proration'] == true);

                            return ListTile(
                              dense: true,
                              leading: const Icon(Icons.list_alt_outlined),
                              title: Text(
                                desc.isEmpty ? '明細' : desc,
                                style: const TextStyle(color: Colors.black87),
                              ),
                              subtitle: Text(
                                isProration
                                    ? '按分（期間途中の差額調整）'
                                    : '数量: $qty  単価: ${_money(unit)} $currency',
                                style: const TextStyle(color: Colors.black54),
                              ),
                              trailing: Text(
                                '${_money(lineTotal)} $currency',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('閉じる'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _resolveFirstTenant() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final qs = await FirebaseFirestore.instance
          .collection(user.uid)
          .limit(1)
          .get();
      if (qs.docs.isNotEmpty) {
        _tenantId = qs.docs.first.id;
        if (mounted) setState(() {});
        await _loadTenantName();
        await _loadAgencyLink();
      }
    } catch (_) {}
  }

  Future<void> _loadTenantName() async {
    final user = FirebaseAuth.instance.currentUser;
    final tid = _tenantId;
    if (user == null || tid == null) return;
    try {
      final doc = await FirebaseFirestore.instance
          .collection(user.uid)
          .doc(tid)
          .get();
      final d = doc.data();
      if (!mounted || d == null) return;
      _tenantName.text =
          (d['name'] as String?) ??
          (d['displayName'] as String?) ??
          _tenantName.text;
    } catch (_) {
      // 読み込み失敗時は何もしない
    }
  }

  // ==== 代理店 ここから ==========================================
  Future<void> _loadAgencyLink() async {
    final user = FirebaseAuth.instance.currentUser;
    final tid = _tenantId;
    if (user == null || tid == null) return;

    try {
      final tenantRef = FirebaseFirestore.instance
          .collection(user.uid)
          .doc(tid);
      final snap = await tenantRef.get();
      final d = snap.data();
      if (!mounted || d == null) return;

      // 画面表示用の店舗名（契約作成に利用）
      final tenantName =
          (d['name'] as String?) ?? (d['displayName'] as String?) ?? 'Store';

      Map<String, dynamic> agency =
          (d['agency'] as Map?)?.cast<String, dynamic>() ?? {};

      final code = (agency['code'] ?? '').toString().trim();
      final linked = agency['linked'] == true;
      final agentId = (agency['agentId'] as String?)?.trim();

      // code があるのに未リンクなら、ここで自動リンクを試みる
      if (code.isNotEmpty && !linked && (agentId == null || agentId.isEmpty)) {
        // agencies を code で逆引き
        final qs = await FirebaseFirestore.instance
            .collection('agencies')
            .where('code', isEqualTo: code)
            .where('status', isEqualTo: 'active')
            .limit(1)
            .get();

        if (qs.docs.isNotEmpty) {
          final ag = qs.docs.first;
          final agentIdFound = ag.id;
          final pct = (ag.data()['commissionPercent'] as num?)?.toInt() ?? 0;

          final merged = {
            ...agency,
            'code': code,
            'agentId': agentIdFound,
            'commissionPercent': pct,
            'linked': true,
            'linkedAt': FieldValue.serverTimestamp(),
          };

          // tenant と tenantIndex を更新
          await tenantRef.set({
            'agency': merged,
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));

          await FirebaseFirestore.instance
              .collection('tenantIndex')
              .doc(tenantRef.id)
              .set({
                'agency': merged,
                'updatedAt': FieldValue.serverTimestamp(),
              }, SetOptions(merge: true));

          // 代理店側 contracts を upsert（active で作成）
          await FirebaseFirestore.instance
              .collection('agencies')
              .doc(agentIdFound)
              .collection('contracts')
              .doc(tenantRef.id)
              .set({
                'tenantId': tenantRef.id,
                'tenantName': tenantName,
                'ownerUid': user.uid,
                'contractedAt': FieldValue.serverTimestamp(),
                'updatedAt': FieldValue.serverTimestamp(),
                'status': 'active',
                'activatedAt': FieldValue.serverTimestamp(),
              }, SetOptions(merge: true));

          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('代理店とリンクしました（code: $code）')));
          }

          agency = merged; // UI 反映用
        }
      }

      final linkedNow = _isAgencyLinked(agency);
      _agency = linkedNow ? agency : null;
      _agencyCodeCtrl.text = linkedNow
          ? ((agency['code'] as String?) ?? '')
          : '';
      if (mounted) setState(() {});
    } catch (_) {
      // no-op
    }
  }

  Future<void> _linkAgency() async {
    final tid = _tenantId;
    final user = FirebaseAuth.instance.currentUser;
    final code = _agencyCodeCtrl.text.trim();
    if (tid == null || user == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('店舗が見つかりません')));
      return;
    }
    if (code.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('代理店コードを入力してください')));
      return;
    }

    setState(() => _linkingAgency = true);
    try {
      final tenantRef = FirebaseFirestore.instance
          .collection(user.uid)
          .doc(tid);

      // 最新テナントを読んで店舗名を取得
      final tSnap = await tenantRef.get();
      final tData = tSnap.data() ?? {};
      final tenantName =
          (tData['name'] as String?) ??
          (tData['displayName'] as String?) ??
          'Store';

      // agencies を code で逆引き
      final qs = await FirebaseFirestore.instance
          .collection('agencies')
          .where('code', isEqualTo: code)
          .where('status', isEqualTo: 'active')
          .limit(1)
          .get();
      if (qs.docs.isEmpty) {
        throw '代理店コードが見つかりません';
      }

      final ag = qs.docs.first;
      final agentId = ag.id;
      final pct = (ag.data()['commissionPercent'] as num?)?.toInt() ?? 0;

      final merged = {
        'code': code,
        'agentId': agentId,
        'commissionPercent': pct,
        'linked': true,
        'linkedAt': FieldValue.serverTimestamp(),
      };

      // tenant / tenantIndex を更新
      await tenantRef.set({
        'agency': merged,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      await FirebaseFirestore.instance
          .collection('tenantIndex')
          .doc(tenantRef.id)
          .set({
            'agency': merged,
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));

      // 代理店側 contracts を upsert（active で作成）
      await FirebaseFirestore.instance
          .collection('agencies')
          .doc(agentId)
          .collection('contracts')
          .doc(tenantRef.id)
          .set({
            'tenantId': tenantRef.id,
            'tenantName': tenantName,
            'ownerUid': user.uid,
            'contractedAt': FieldValue.serverTimestamp(),
            'updatedAt': FieldValue.serverTimestamp(),
            'status': 'active',
            'activatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));

      // UI 更新
      _agency = merged;
      _agencyCodeCtrl.text = code;
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('代理店と連携しました')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e is String ? e : '連携に失敗: $e')));
      }
    } finally {
      if (mounted) setState(() => _linkingAgency = false);
    }
  }
  // ==== 代理店 ここまで ==========================================

  @override
  void dispose() {
    _tenantName.dispose();
    _agencyCodeCtrl.dispose(); // 代理店
    super.dispose();
  }

  Future<void> _saveTenant() async {
    final user = FirebaseAuth.instance.currentUser;
    final tid = _tenantId;
    if (user == null || tid == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('店舗が見つかりません')));
      return;
    }
    final newName = _tenantName.text.trim();
    if (newName.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('店舗名を入力してください')));
      return;
    }

    setState(() => _saving = true);
    try {
      final tref = FirebaseFirestore.instance.collection(user.uid).doc(tid);
      await tref.set({
        'name': newName,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('店舗名を保存しました')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('保存に失敗: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  bool _isAgencyLinked(Map<String, dynamic>? a) {
    if (a == null) return false;
    final code = (a['code'] as String?)?.trim() ?? '';
    final linked = a['linked'] == true;
    final uid = (a['uid'] as String?)?.trim() ?? '';
    final linkedAt = a['linkedAt']; // Timestamp/int/string のどれかが入り得る

    // どれかが満たされれば「連携済み」扱い
    // - linked が true
    // - code が空でなく、かつ uid あり or linkedAt あり
    return linked || (code.isNotEmpty && (uid.isNotEmpty || linkedAt != null));
  }

  Future<void> _openCustomerPortalForPaymentMethod() async {
    final tid = _tenantId;
    if (tid == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('店舗が見つかりません')));
      return;
    }

    setState(() => _openingCustomerPortal = true);
    try {
      await FirebaseAuth.instance.currentUser?.getIdToken(true);
      final fn = FirebaseFunctions.instanceFor(
        region: 'us-central1',
      ).httpsCallable('createCustomerPortalSession');

      // ★ サーバに「支払方法のみ」モードを明示
      final resp = await fn.call({
        'tenantId': tid,
        'flow': 'payment_method_update',
        'pmOnly': true,
      });
      final url = (resp.data as Map?)?['url'] as String?;
      if (url == null || url.isEmpty) throw 'URLが取得できませんでした';

      final ok = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
        webOnlyWindowName: '_self',
      );
      if (!ok) throw 'ブラウザ起動に失敗しました';
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('エラー: $e')));
      }
    } finally {
      if (mounted) setState(() => _openingCustomerPortal = false);
    }
  }

  // ===== Stripe: 請求一覧 =====
  Future<void> _loadInvoices(String tenantId) async {
    setState(() => _loadingInvoices = true);
    try {
      final fn = FirebaseFunctions.instanceFor(
        region: 'us-central1',
      ).httpsCallable('listInvoices');
      final res = await fn.call({'tenantId': tenantId, 'limit': 24});
      final map = (res.data as Map?) ?? const {};
      _invoices = (map['invoices'] as List? ?? []).cast<Map<String, dynamic>>();
      _oneTime = (map['one_time'] as List? ?? []).cast<Map<String, dynamic>>();
      _history = (map['history'] as List? ?? []).cast<Map<String, dynamic>>();
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

  Future<void> _showInvoicesDialog(BuildContext context) async {
    if (_tenantId == null) return;
    if (_history.isEmpty && !_loadingInvoices) {
      await _loadInvoices(_tenantId!);
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, sbSet) {
          String _fmtYMD(DateTime d) =>
              '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';

          DateTime _toDate(dynamic raw) {
            if (raw is int)
              return DateTime.fromMillisecondsSinceEpoch(raw * 1000);
            if (raw is double)
              return DateTime.fromMillisecondsSinceEpoch((raw * 1000).round());
            if (raw is Timestamp) return raw.toDate();
            return DateTime.now();
          }

          Widget _historyTile(Map<String, dynamic> h) {
            final type = (h['type'] ?? '').toString();
            final created = _toDate(h['created']);
            final ymd = _fmtYMD(created);
            final amount = ((h['amount'] ?? 0) as num).toDouble();
            final cur = (h['currency'] ?? 'JPY').toString().toUpperCase();
            final amountDisp = (amount / 100).toStringAsFixed(2);
            final status = (h['status'] ?? '').toString();
            final url = h['url'] as String?;
            final isInvoice = type == 'invoice';
            final title = isInvoice ? '請求書（$ymd）' : '初期費用 / 都度決済（$ymd）';
            final icon = isInvoice
                ? Icons.receipt_long
                : Icons.payments_outlined;

            return ListTile(
              leading: CircleAvatar(
                backgroundColor: Colors.black12,
                child: Icon(icon, color: Colors.black87),
              ),
              title: Text(title, style: const TextStyle(color: Colors.black87)),
              subtitle: Text(
                '金額: $amountDisp $cur  •  ステータス: $status',
                style: const TextStyle(color: Colors.black54),
              ),
              trailing: (url == null)
                  ? null
                  : IconButton(
                      tooltip: isInvoice ? '請求書/領収書を開く' : '領収書を開く',
                      icon: const Icon(Icons.open_in_new),
                      onPressed: () => launchUrlString(
                        url,
                        mode: LaunchMode.externalApplication,
                        webOnlyWindowName: '_self',
                      ),
                    ),
            );
          }

          Widget _buildList(
            List<Map<String, dynamic>> src, {
            bool fromHistory = false,
          }) {
            if (_loadingInvoices) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(),
                ),
              );
            }
            if (src.isEmpty) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    '履歴はまだありません',
                    style: TextStyle(color: Colors.black87),
                  ),
                ),
              );
            }

            return ListView.separated(
              itemCount: src.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final row = src[i];
                if (fromHistory) return _historyTile(row);

                if (row.containsKey('kind') &&
                    row['kind'] == 'payment_intent') {
                  final created = _toDate(row['created']);
                  final ymd = _fmtYMD(created);
                  final amount = ((row['amount'] ?? 0) as num).toDouble();
                  final cur = (row['currency'] ?? 'JPY')
                      .toString()
                      .toUpperCase();
                  final status = (row['status'] ?? '').toString();
                  final url = row['receipt_url'] as String?;
                  return ListTile(
                    leading: const CircleAvatar(
                      backgroundColor: Colors.black12,
                      child: Icon(
                        Icons.payments_outlined,
                        color: Colors.black87,
                      ),
                    ),
                    title: Text(
                      '初期費用 / 都度決済（$ymd）',
                      style: const TextStyle(color: Colors.black87),
                    ),
                    subtitle: Text(
                      '金額: ${(amount / 100).toStringAsFixed(2)} $cur  •  ステータス: $status',
                      style: const TextStyle(color: Colors.black54),
                    ),
                    trailing: (url == null)
                        ? null
                        : IconButton(
                            tooltip: '領収書を開く',
                            icon: const Icon(Icons.open_in_new),
                            onPressed: () => launchUrlString(
                              url,
                              mode: LaunchMode.externalApplication,
                              webOnlyWindowName: '_self',
                            ),
                          ),
                  );
                } else {
                  final amount =
                      ((row['amount_paid'] ?? row['amount_due'] ?? 0) as num)
                          .toDouble();
                  final cur = (row['currency'] ?? 'JPY')
                      .toString()
                      .toUpperCase();
                  final number = (row['number'] ?? row['id'] ?? '').toString();
                  final url = row['hosted_invoice_url'] as String?;
                  final pdf = row['invoice_pdf'] as String?;
                  final created = _toDate(row['created']);
                  final ymd = _fmtYMD(created);

                  return ListTile(
                    leading: const CircleAvatar(
                      backgroundColor: Colors.black12,
                      child: Icon(Icons.receipt_long, color: Colors.black87),
                    ),
                    title: Text(
                      '請求 #$number（$ymd）',
                      style: const TextStyle(color: Colors.black87),
                    ),
                    subtitle: Text(
                      '支払額: ${(amount / 100).toStringAsFixed(2)} $cur  •  状態: ${row['status']}',
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
                              mode: LaunchMode.platformDefault,
                              webOnlyWindowName: "_self",
                            ),
                          ),
                        if (url != null)
                          IconButton(
                            tooltip: '請求書ページを開く',
                            icon: const Icon(Icons.open_in_new),
                            onPressed: () => launchUrlString(
                              url,
                              mode: LaunchMode.externalApplication,
                              webOnlyWindowName: '_self',
                            ),
                          ),
                      ],
                    ),
                  );
                }
              },
            );
          }

          return DefaultTabController(
            length: 3,
            child: AlertDialog(
              backgroundColor: Colors.white,
              surfaceTintColor: Colors.transparent,
              title: Row(
                children: [
                  const Text(
                    '請求・支払い履歴',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  OutlinedButton.icon(
                    onPressed: _loadingInvoices
                        ? null
                        : () async {
                            await _loadInvoices(_tenantId!);
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
              content: SizedBox(
                width: 700,
                height: 520,
                child: Column(
                  children: [
                    const TabBar(
                      labelColor: Colors.black,
                      tabs: [
                        Tab(text: 'すべて'),
                        Tab(text: '請求書'),
                        Tab(text: '初期費用'),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: TabBarView(
                        children: [
                          _buildList(_history, fromHistory: true),
                          _buildList(_invoices),
                          _buildList(_oneTime),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text(
                    '閉じる',
                    style: TextStyle(color: Colors.black87),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ===== Stripe: コネクトアカウント（口座確認/更新） =====
  Future<void> _openConnectPortal() async {
    final tid = _tenantId;
    if (tid == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('店舗が見つかりません')));
      return;
    }

    setState(() => _openingConnectPortal = true);
    try {
      await FirebaseAuth.instance.currentUser?.getIdToken(true);
      final fn = FirebaseFunctions.instanceFor(
        region: 'us-central1',
      ).httpsCallable('createConnectAccountLink');
      final resp = await fn.call({'tenantId': tid});
      final url = (resp.data as Map?)?['url'] as String?;
      if (url == null || url.isEmpty) {
        throw 'URLが取得できませんでした';
      }

      final ok = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
      if (!ok) throw 'ブラウザ起動に失敗しました';
    } on FirebaseFunctionsException catch (e) {
      final code = e.code;
      final msg = e.message ?? '';
      final friendly = switch (code) {
        'unauthenticated' => 'ログイン情報が無効です。再ログインしてお試しください。',
        'invalid-argument' => '必要な情報が不足しています（tenantId）。',
        'permission-denied' => '権限がありません。',
        _ => 'リンク作成に失敗: $code $msg',
      };
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(friendly)));
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('エラー: $e')));
    } finally {
      if (mounted) setState(() => _openingConnectPortal = false);
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

    final currentUid = FirebaseAuth.instance.currentUser?.uid;

    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 0,
        title: const Text(
          '店舗設定',
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _FieldCard(
                title: '店舗情報',
                child: Column(
                  children: [
                    TextField(
                      controller: _tenantName,
                      decoration: const InputDecoration(
                        labelText: '店舗名（テナント名）',
                      ),
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _saveTenant(),
                    ),
                    if (_tenantId == null)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text(
                          '※ 店舗が未選択のため編集できません。',
                          style: TextStyle(color: Colors.black54, fontSize: 12),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  style: primaryBtnStyle,
                  onPressed: (_tenantId == null || _saving)
                      ? null
                      : _saveTenant,
                  icon: _saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.save),
                  label: const Text('保存する'),
                ),
              ),
              const SizedBox(height: 24),

              // ==== 代理店 ここから ==========================================
              _FieldCard(
                title: '代理店コード',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_isAgencyLinked(_agency)) ...[
                      // 連携済み表示
                      Row(
                        children: [
                          const Icon(Icons.verified, color: Colors.green),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '連携済み：${(_agency!['name'] ?? '').toString().isEmpty ? '代理店' : _agency!['name']}'
                              '（コード: ${(_agency!['code'] ?? '').toString()}）',
                              style: const TextStyle(color: Colors.black87),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _agencyCodeCtrl,
                        readOnly: true,
                        decoration: const InputDecoration(
                          labelText: '代理店コード',
                          helperText: 'すでに代理店と連携済みです',
                        ),
                      ),
                    ] else ...[
                      // 未連携：入力欄 + 連携ボタン
                      TextField(
                        controller: _agencyCodeCtrl,
                        decoration: const InputDecoration(
                          labelText: '代理店コード',
                          hintText: '例: ABC123',
                        ),
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) =>
                            (_tenantId == null || _linkingAgency)
                            ? null
                            : _linkAgency(),
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton.icon(
                          onPressed: (_tenantId == null || _linkingAgency)
                              ? null
                              : _linkAgency,
                          icon: _linkingAgency
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.link),
                          label: const Text('連携する'),
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.black,
                            foregroundColor: Colors.white,
                          ),
                        ),
                      ),
                      if (_tenantId == null)
                        const Padding(
                          padding: EdgeInsets.only(top: 8),
                          child: Text(
                            '※ 店舗が未選択のため連携できません。',
                            style: TextStyle(
                              color: Colors.black54,
                              fontSize: 12,
                            ),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 24),
              // ==== 代理店 ここまで ==========================================

              // ===== Stripe 連携 =====
              _FieldCard(
                title: 'Stripe 連携',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _StripeRow(
                      icon: Icons.account_balance_wallet,
                      title: '入金履歴',
                      subtitle: '接続アカウントへの入金と、その内訳明細を確認します。',
                      trailing: FilledButton(
                        onPressed: (_tenantId == null || _loadingPayouts)
                            ? null
                            : _loadPayouts,
                        child: _loadingPayouts
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('開く'),
                      ),
                    ),
                    const SizedBox(height: 10),

                    _StripeRow(
                      icon: Icons.credit_card,
                      title: '支払方法の変更',
                      subtitle: 'サブスクリプションで利用するカード/支払い方法を更新します。',
                      trailing: FilledButton(
                        onPressed: (_tenantId == null || _openingCustomerPortal)
                            ? null
                            : _openCustomerPortalForPaymentMethod,
                        child: _openingCustomerPortal
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('変更'),
                      ),
                    ),
                    const SizedBox(height: 10),
                    _StripeRow(
                      icon: Icons.event_available,
                      title: '請求予定を確認',
                      subtitle: '次回の請求日・合計金額・明細を確認します。',
                      trailing: FilledButton(
                        onPressed: (_tenantId == null || _loadingUpcoming)
                            ? null
                            : _fetchUpcomingInvoice,
                        child: _loadingUpcoming
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('確認'),
                      ),
                    ),
                    const SizedBox(height: 10),

                    _StripeRow(
                      icon: Icons.receipt_long,
                      title: '請求書履歴',
                      subtitle: 'サポート費用・サブスクリプションの支払い履歴を確認する。',
                      trailing: FilledButton(
                        onPressed: (_tenantId == null || _loadingInvoices)
                            ? null
                            : () => _showInvoicesDialog(context),
                        child: _loadingInvoices
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('開く'),
                      ),
                    ),
                    const SizedBox(height: 10),
                    _StripeRow(
                      icon: Icons.account_balance,
                      title: 'コネクトアカウント',
                      subtitle: 'チップ受け取り口座を確認する。',
                      trailing: FilledButton(
                        onPressed: (_tenantId == null || _loadingInvoices)
                            ? null
                            : () => _openConnectPortal,
                        child: _loadingInvoices
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('開く'),
                      ),
                    ),
                    const SizedBox(height: 10),

                    // 解約ブロック（契約状況に応じた文言）
                    StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                      stream: (_tenantId == null)
                          ? const Stream.empty()
                          : FirebaseFirestore.instance
                                .collection(currentUid ?? '')
                                .doc(_tenantId)
                                .snapshots(),
                      builder: (context, snap) {
                        int? _asInt(dynamic v) => (v is int)
                            ? v
                            : (v is double)
                            ? v.round()
                            : null;

                        String _fmtYMD(DateTime d) =>
                            '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';

                        String subtitle = '一度解約すると、トライアルを再開することはできません。';
                        if (snap.hasData && snap.data!.data() != null) {
                          final sub =
                              (snap.data!.data()!['subscription'] as Map?) ??
                              {};
                          final status = (sub['status'] ?? '').toString();
                          final cancelAtPeriodEnd =
                              (sub['cancelAtPeriodEnd'] == true);
                          final cancelAt = _asInt(sub['cancelAt']);
                          final currentPeriodEnd = _asInt(
                            sub['currentPeriodEnd'],
                          );

                          if (cancelAtPeriodEnd) {
                            if (cancelAt != null) {
                              subtitle =
                                  '解約予定日: ${_fmtYMD(DateTime.fromMillisecondsSinceEpoch(cancelAt * 1000))}（一度解約するとトライアルは再開できません）';
                            } else {
                              subtitle =
                                  '解約は次回更新時に停止します（キャンセル予約中）。一度解約するとトライアルは再開できません。';
                            }
                          } else {
                            if (status != 'trialing' &&
                                currentPeriodEnd != null) {
                              subtitle =
                                  '解約すると次回更新（${_fmtYMD(DateTime.fromMillisecondsSinceEpoch(currentPeriodEnd * 1000))}）で停止します。 一度解約するとトライアルは再開できません。';
                            } else if (status == 'trialing') {
                              subtitle =
                                  'トライアル中は解約すると即時停止します。一度解約するとトライアルは再開できません。';
                            }
                          }
                        }

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _StripeRow(
                              icon: Icons.cancel_schedule_send,
                              title: 'サブスクリプション解約',
                              subtitle: subtitle,
                              trailing: FilledButton(
                                style: FilledButton.styleFrom(
                                  backgroundColor: Colors.black,
                                  foregroundColor: Colors.grey,
                                ),
                                onPressed: (_tenantId == null || _cancelingSub)
                                    ? null
                                    : _cancelSubscription,
                                child: _cancelingSub
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.white,
                                        ),
                                      )
                                    : const Text('解約'),
                              ),
                            ),
                            if (_tenantId == null)
                              const Padding(
                                padding: EdgeInsets.only(top: 8),
                                child: Text(
                                  '※ 店舗が未選択のためボタンを無効化しています。',
                                  style: TextStyle(
                                    color: Colors.black54,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                          ],
                        );
                      },
                    ),

                    if (_tenantId == null)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text(
                          '※ 店舗が未選択のためボタンを無効化しています。',
                          style: TextStyle(color: Colors.black54, fontSize: 12),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FieldCard extends StatelessWidget {
  final String title;
  final Widget child;
  const _FieldCard({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1A000000),
            blurRadius: 16,
            offset: Offset(0, 8),
          ),
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _StripeRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget trailing;
  const _StripeRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(10),
          ),
          padding: const EdgeInsets.all(8),
          child: Icon(icon, color: Colors.white, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: const TextStyle(color: Colors.black54, fontSize: 12),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        trailing,
      ],
    );
  }
}
