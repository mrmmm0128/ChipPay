import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:yourpay/tenant/widget/subscription_card.dart';

enum RecipientFilter { all, storeOnly, staffOnly }

class PeriodPaymentsPage extends StatefulWidget {
  final String tenantId;
  final String? tenantName;
  final DateTime? start;
  final DateTime? endExclusive;

  // ルートから渡された初期フィルタ
  final RecipientFilter recipientFilter;

  const PeriodPaymentsPage({
    super.key,
    required this.tenantId,
    this.tenantName,
    this.start,
    this.endExclusive,
    this.recipientFilter = RecipientFilter.all,
  });

  @override
  State<PeriodPaymentsPage> createState() => _PeriodPaymentsPageState();
}

class _PeriodPaymentsPageState extends State<PeriodPaymentsPage> {
  final _searchCtrl = TextEditingController();
  String _search = '';
  Timer? _debounce;
  final uid = FirebaseAuth.instance.currentUser?.uid;

  // ▼ 追加：UIで操作する現在のフィルタ値
  late RecipientFilter _currentRecipientFilter;
  String _pmFilter =
      'all'; // 'all' / 'card' / 'apple_pay' / 'google_pay' / 'konbini' / 'link' / 'alipay' / 'wechat_pay' / 'other'

  @override
  void initState() {
    super.initState();
    _currentRecipientFilter = widget.recipientFilter; // ルート初期値を反映
    _searchCtrl.addListener(() {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 180), () {
        setState(() => _search = _searchCtrl.text.trim().toLowerCase());
      });
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  String _symbol(String code) {
    switch (code.toUpperCase()) {
      case 'JPY':
        return '¥';
      case 'USD':
        return '\$';
      case 'EUR':
        return '€';
      default:
        return '';
    }
  }

  String _rangeLabel() {
    if (widget.start == null && widget.endExclusive == null) return '全期間';
    String f(DateTime d) =>
        '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';
    final s = widget.start != null ? f(widget.start!) : '…';
    final e = (widget.endExclusive != null)
        ? f(widget.endExclusive!.subtract(const Duration(days: 1)))
        : '…';
    return '$s 〜 $e';
  }

  // 受取先フィルタのラベル
  String _recipientFilterLabel(RecipientFilter f) {
    switch (f) {
      case RecipientFilter.storeOnly:
        return '店舗のみ';
      case RecipientFilter.staffOnly:
        return 'スタッフのみ';
      case RecipientFilter.all:
        return 'すべて';
    }
  }

  // 決済方法の選択肢（キー→表示名）
  static const Map<String, String> _pmOptions = {
    'all': '決済: すべて',
    'card': 'クレジットカード',
    'apple_pay': 'Apple Pay',
    'google_pay': 'Google Pay',
    'konbini': 'コンビニ払い',
    'link': 'Link',
    'alipay': 'Alipay',
    'wechat_pay': 'WeChat Pay',
    'other': 'その他',
  };

  Query _buildQuery() {
    Query q = FirebaseFirestore.instance
        .collection(uid!)
        .doc(widget.tenantId)
        .collection('tips')
        .where('status', isEqualTo: 'succeeded');

    if (widget.start != null) {
      q = q.where(
        'createdAt',
        isGreaterThanOrEqualTo: Timestamp.fromDate(widget.start!),
      );
    }
    if (widget.endExclusive != null) {
      q = q.where(
        'createdAt',
        isLessThan: Timestamp.fromDate(widget.endExclusive!),
      );
    }

    return q.orderBy('createdAt', descending: true).limit(500);
  }

  String _nameFrom(Map<String, dynamic> d) {
    final rec = (d['recipient'] as Map?)?.cast<String, dynamic>();
    final isEmp = (rec?['type'] == 'employee') || (d['employeeId'] != null);
    if (isEmp) {
      return (rec?['employeeName'] ?? d['employeeName'] ?? 'スタッフ').toString();
    } else {
      return (rec?['storeName'] ?? d['storeName'] ?? '店舗').toString();
    }
  }

  // 決済方法のキーを抽出（フィルタ用に正規化）
  // 返り値例: 'card' / 'apple_pay' / 'google_pay' / 'konbini' / 'link' / 'alipay' / 'wechat_pay' / 'other' / null(不明)
  String? _pmKeyFromDoc(Map<String, dynamic> d) {
    final pay = ((d['payment'] ?? d['paymentSummary']) as Map?)
        ?.cast<String, dynamic>();
    if (pay == null) return null;

    final methodRaw = (pay['method'] as String?)?.toLowerCase();
    final card =
        (pay['card'] as Map?)?.cast<String, dynamic>() ??
        (pay['cardOnCharge'] as Map?)?.cast<String, dynamic>() ??
        (pay['cardOnPM'] as Map?)?.cast<String, dynamic>();
    final wallet =
        ((card?['wallet'] as Map?)?['type'] ??
                pay['wallet'] ??
                pay['walletType'])
            ?.toString()
            .toLowerCase();

    String normalize(String? m) {
      if (m == null) return 'other';
      if (m == 'card') {
        if (wallet == 'apple_pay') return 'apple_pay';
        if (wallet == 'google_pay') return 'google_pay';
        return 'card';
      }
      const known = {'konbini', 'link', 'alipay', 'wechat_pay'};
      return known.contains(m) ? m : 'other';
    }

    return normalize(methodRaw);
  }

  // 決済方法の日本語ラベル（表示用）
  String _pmLabelFromDoc(Map<String, dynamic> d) {
    final pay = ((d['payment'] ?? d['paymentSummary']) as Map?)
        ?.cast<String, dynamic>();
    if (pay == null) return '';

    final methodRaw = (pay['method'] as String?)?.toLowerCase();
    final card =
        (pay['card'] as Map?)?.cast<String, dynamic>() ??
        (pay['cardOnCharge'] as Map?)?.cast<String, dynamic>() ??
        (pay['cardOnPM'] as Map?)?.cast<String, dynamic>();

    final brand = (card?['brand'] ?? pay['cardBrand'])?.toString();
    final last4 = (card?['last4'] ?? pay['cardLast4'])?.toString();
    final wallet =
        ((card?['wallet'] as Map?)?['type'] ??
                pay['wallet'] ??
                pay['walletType'])
            ?.toString()
            .toLowerCase();

    String jpMethod(String? m) {
      switch (m) {
        case 'card':
          if (wallet == 'apple_pay') return 'Apple Pay';
          if (wallet == 'google_pay') return 'Google Pay';
          return 'クレジットカード';
        case 'konbini':
          return 'コンビニ払い';
        case 'link':
          return 'Link';
        case 'alipay':
          return 'Alipay';
        case 'wechat_pay':
          return 'WeChat Pay';
        default:
          return (m ?? 'その他').toUpperCase();
      }
    }

    final base = jpMethod(methodRaw);
    if (methodRaw == 'card') {
      final tailBrand = (brand != null && brand.isNotEmpty)
          ? brand.toUpperCase()
          : 'カード';
      final tail4 = (last4 != null && last4.isNotEmpty) ? ' •••• $last4' : '';
      if (wallet == 'apple_pay' || wallet == 'google_pay') {
        return '$base（$tailBrand$tail4）';
      }
      return '$tailBrand$tail4';
    }
    return base;
  }

  @override
  Widget build(BuildContext context) {
    final q = _buildQuery();

    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF7F7F7),
        foregroundColor: Colors.black,
        elevation: 0,
        title: Text(
          widget.tenantName == null ? '決済履歴' : '${widget.tenantName!} の決済履歴',
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
        ),
        bottom: PreferredSize(
          // UIを1段増やしたので少し高さを足す
          preferredSize: const Size.fromHeight(132),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 範囲の表示
                Text(
                  _rangeLabel(),
                  style: const TextStyle(color: Colors.black54),
                ),
                const SizedBox(height: 8),

                // 検索
                TextField(
                  controller: _searchCtrl,
                  decoration: InputDecoration(
                    hintText: '名前で検索（スタッフ名 / 店舗名）',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _search.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () => _searchCtrl.clear(),
                          ),
                    isDense: true,
                    filled: true,
                    fillColor: const Color(0xFFF0F0F0),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 8),

                // ▼ プルダウン2種：受取先 / 決済方法
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<RecipientFilter>(
                        value: _currentRecipientFilter,
                        decoration: InputDecoration(
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          filled: true,
                          fillColor: const Color(0xFFF0F0F0),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                          prefixIcon: const Icon(Icons.filter_alt_outlined),
                          labelText: '受取先',
                          labelStyle: const TextStyle(color: Colors.black54),
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: RecipientFilter.all,
                            child: Text('すべて'),
                          ),
                          DropdownMenuItem(
                            value: RecipientFilter.storeOnly,
                            child: Text('店舗のみ'),
                          ),
                          DropdownMenuItem(
                            value: RecipientFilter.staffOnly,
                            child: Text('スタッフのみ'),
                          ),
                        ],
                        onChanged: (v) {
                          if (v == null) return;
                          setState(() => _currentRecipientFilter = v);
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: _pmFilter,
                        decoration: InputDecoration(
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          filled: true,
                          fillColor: const Color(0xFFF0F0F0),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                          prefixIcon: const Icon(Icons.credit_card),
                          labelText: '決済方法',
                          labelStyle: const TextStyle(color: Colors.black54),
                        ),
                        items: _pmOptions.entries
                            .map(
                              (e) => DropdownMenuItem<String>(
                                value: e.key,
                                child: Text(e.value),
                              ),
                            )
                            .toList(),
                        onChanged: (v) {
                          if (v == null) return;
                          setState(() => _pmFilter = v);
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: q.snapshots(),
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: Text('読み込みエラー: ${snap.error}'));
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final docs = snap.data!.docs;

          // 受取先・決済方法・名前検索の順でクライアント側フィルタ
          final filtered = (() {
            Iterable<QueryDocumentSnapshot> it = docs;

            // 受取先（店舗/スタッフ）
            it = it.where((doc) {
              final d = doc.data() as Map<String, dynamic>;
              final rec = (d['recipient'] as Map?)?.cast<String, dynamic>();
              final isStaff =
                  (rec?['type'] == 'employee') || (d['employeeId'] != null);
              switch (_currentRecipientFilter) {
                case RecipientFilter.storeOnly:
                  return !isStaff;
                case RecipientFilter.staffOnly:
                  return isStaff;
                case RecipientFilter.all:
                  return true;
              }
            });

            // 決済方法
            if (_pmFilter != 'all') {
              it = it.where((doc) {
                final d = doc.data() as Map<String, dynamic>;
                final key = _pmKeyFromDoc(d); // nullなら一致しない扱い
                if (key == null) return false;
                if (_pmFilter == 'other') {
                  // otherは既知以外を拾う
                  return key == 'other';
                }
                return key == _pmFilter;
              });
            }

            // 名前検索（部分一致）
            if (_search.isNotEmpty) {
              it = it.where((doc) {
                final d = doc.data() as Map<String, dynamic>;
                final name = _nameFrom(d).toLowerCase();
                return name.contains(_search);
              });
            }

            return it.toList();
          })();

          if (filtered.isEmpty) {
            return const Center(child: Text('該当するデータはありません'));
          }

          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: filtered.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (_, i) {
              final d = filtered[i].data() as Map<String, dynamic>;
              final rec = (d['recipient'] as Map?)?.cast<String, dynamic>();
              final isEmp =
                  (rec?['type'] == 'employee') || (d['employeeId'] != null);

              final who = isEmp
                  ? 'スタッフ: ${rec?['employeeName'] ?? d['employeeName'] ?? 'スタッフ'}'
                  : '店舗: ${rec?['storeName'] ?? d['storeName'] ?? '店舗'}';

              // 元金（支払額）
              final amountNum = (d['amount'] as num?) ?? 0;
              final currency =
                  (d['currency'] as String?)?.toUpperCase() ?? 'JPY';
              final sym = _symbol(currency);
              final amountText = sym.isNotEmpty
                  ? '$sym${amountNum.toInt()}'
                  : '${amountNum.toInt()} $currency';

              // 決済方法表示
              final pmText = _pmLabelFromDoc(d);

              // 日時
              String when = '';
              final ts = d['createdAt'];
              if (ts is Timestamp) {
                final dt = ts.toDate().toLocal();
                when =
                    '${dt.year}/${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')} '
                    '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
              }

              return CardShell(
                child: ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Colors.black,
                    foregroundColor: Colors.white,
                    child: Icon(Icons.receipt_long),
                  ),
                  title: Text(
                    who,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      color: Colors.black87,
                    ),
                  ),
                  subtitle: Text(
                    pmText.isEmpty ? when : '$when\n$pmText',
                    style: const TextStyle(color: Colors.black87),
                  ),
                  isThreeLine: pmText.isNotEmpty,
                  trailing: Text(
                    amountText,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: Colors.black87,
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
