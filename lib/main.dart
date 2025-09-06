import 'dart:async';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:easy_localization/easy_localization.dart';

import 'package:yourpay/admin/admin_dashboard_screen.dart';
import 'package:yourpay/admin/admin_login_screen.dart';
import 'package:yourpay/admin/admin_tenant_detrail_screen.dart';
import 'package:yourpay/endUser/tip_complete_page.dart';
import 'package:yourpay/tenant/account_detail_screen.dart';
import 'package:yourpay/endUser/public_store_page.dart';
import 'package:yourpay/endUser/staff_detail_page.dart';
import 'package:yourpay/tenant/staff_qr/public_staff_qr_list_page.dart';
import 'package:yourpay/tenant/staff_qr/qr_poster_build_page.dart';
import 'package:yourpay/tenant/store_admin_add/accept_invite_screen.dart';
import 'package:yourpay/tenant/store_list_screen.dart';
import 'tenant/login_screens.dart';
import 'tenant/store_detail_screen.dart';
import 'endUser/payer_landing_screen.dart';

// ===== Firebase options（そのままでOK） =====
const firebaseOptions = FirebaseOptions(
  apiKey: 'AIzaSyDePrpR8CD5xWf19828aGwdgVve5s4EYOc',
  appId: '1:362152912464:web:223f3abe2183994303d355',
  messagingSenderId: '362152912464',
  projectId: 'muscleshare-b34dd',
  authDomain: 'muscleshare-b34dd.firebaseapp.com',
  storageBucket: 'muscleshare-b34dd.firebasestorage.app',
  measurementId: 'G-DH77D7G3L3',
);

Future<void> main() async {
  setUrlStrategy(const HashUrlStrategy());
  WidgetsFlutterBinding.ensureInitialized();
  await EasyLocalization.ensureInitialized();
  await Firebase.initializeApp(options: firebaseOptions);
  // await _connectToEmulatorsIfDebug();

  // 画面が真っ白になっても原因が見えるように
  ErrorWidget.builder = (FlutterErrorDetails details) {
    if (kReleaseMode) {
      return const Material(
        color: Colors.white,
        child: Center(
          child: Text('Unexpected error', style: TextStyle(color: Colors.red)),
        ),
      );
    }
    return Material(
      color: Colors.white,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Text(
          details.exceptionAsString(),
          style: const TextStyle(color: Colors.red),
        ),
      ),
    );
  };

  runZonedGuarded(
    () {
      runApp(
        EasyLocalization(
          supportedLocales: const [
            Locale('en'),
            Locale('ja'),
            Locale('ko'),
            Locale('zh'),
          ],
          path: 'assets/translations',
          fallbackLocale: const Locale('en'),
          useOnlyLangCode: true,
          child: const MyApp(),
        ),
      );
    },
    (error, stack) {
      // Webのコンソールにも確実に出す
      // ignore: avoid_print
      print('Uncaught zone error: $error\n$stack');
    },
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  Route<dynamic> _onGenerateRoute(RouteSettings settings) {
    final name = settings.name ?? '/';
    final uri = Uri.parse(name);

    // /payer?sid=...
    if (uri.path == '/payer') {
      final sid = uri.queryParameters['sid'] ?? '';
      return MaterialPageRoute(
        builder: (_) => PayerLandingScreen(sessionId: sid),
        settings: settings,
      );
    }

    // /p?t=... [&thanks=true|&canceled=true]
    if (uri.path == '/p') {
      final tid = uri.queryParameters['t'] ?? '';

      final thanks = uri.queryParameters['thanks'] == 'true';
      final canceled = uri.queryParameters['canceled'] == 'true';
      if (thanks || canceled) {
        return MaterialPageRoute(
          builder: (_) => TipCompletePage(
            tenantId: tid,
            tenantName: uri.queryParameters['tenantName'],
            amount: int.tryParse(uri.queryParameters['amount'] ?? ''),
            employeeName: uri.queryParameters['employeeName'],
          ),
          settings: settings,
        );
      }

      return MaterialPageRoute(
        builder: (_) => const PublicStorePage(),
        settings: RouteSettings(
          name: settings.name,
          arguments: {'tenantId': tid},
        ),
      );
    }

    // それ以外の静的ルート
    final staticRoutes = <String, WidgetBuilder>{
      '/': (_) => const Root(),
      '/login': (_) => const LoginScreen(),
      '/stores': (_) => const StoreListScreen(),
      '/store': (_) => const StoreDetailScreen(),
      '/store/staff': (_) => const StaffDetailPage(),
      '/account': (_) => const AccountDetailScreen(),
      '/admin-login': (_) => const AdminLoginScreen(),
      '/admin': (_) => const AdminDashboardScreen(),
      '/admin/tenant': (_) => const AdminTenantDetailScreen(),
      '/admin-invite': (_) => const AcceptInviteScreen(),
      '/qr-all': (_) => const PublicStaffQrListPage(),
      'qr-all/qr-builder': (_) => const QrPosterBuilderPage(),
      '/chechout-end': (_) => const LoginScreen(),
    };

    final builder = staticRoutes[uri.path];
    return MaterialPageRoute(
      builder: builder ?? (_) => const LoginScreen(),
      settings: settings,
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,

      // easy_localization
      localizationsDelegates: context.localizationDelegates,
      supportedLocales: context.supportedLocales,
      locale: context.locale,

      // テーマ（ライト基調：白背景で“真っ白=クラッシュ”と区別しやすい）
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.black,
          brightness: Brightness.light,
        ),
        fontFamily: 'LINESeed',
      ),

      // 初期画面は Root（ここで公開/非公開を振り分け）
      home: const Root(),

      // 以降の named push はここで解決
      onGenerateRoute: _onGenerateRoute,
    );
  }
}

class Root extends StatelessWidget {
  const Root({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        // ハッシュURL対応（/#/qr-all?… → /qr-all）
        String currentPath() {
          final uri = Uri.base;
          if (uri.fragment.isNotEmpty) {
            final frag = uri.fragment; // "/qr-all?t=xxx"
            final q = frag.indexOf('?');
            return q >= 0 ? frag.substring(0, q) : frag; // "/qr-all"
          }
          return uri.path;
        }

        final path = currentPath();
        const publicPaths = {'/qr-all', '/qr-builder', '/staff', '/p'};

        if (snap.data == null && publicPaths.contains(path)) {
          switch (path) {
            case '/qr-all':
              return const PublicStaffQrListPage();
            case '/qr-builder':
              return const QrPosterBuilderPage();
            case '/staff':
              return const StaffDetailPage();
            case '/p':
              return const PublicStorePage();
          }
        }

        if (snap.data == null) {
          return const LoginScreen();
        }

        return const StoreOrAdminSwitcher();
      },
    );
  }
}

class StoreOrAdminSwitcher extends StatefulWidget {
  const StoreOrAdminSwitcher({super.key});

  @override
  State<StoreOrAdminSwitcher> createState() => _StoreOrAdminSwitcherState();
}

class _StoreOrAdminSwitcherState extends State<StoreOrAdminSwitcher> {
  String? _role;

  @override
  void initState() {
    super.initState();
    _loadClaims();
  }

  Future<void> _loadClaims() async {
    final user = FirebaseAuth.instance.currentUser!;
    final result = await user.getIdTokenResult(true);
    setState(() => _role = (result.claims?['role'] as String?) ?? 'staff');
  }

  @override
  Widget build(BuildContext context) {
    if (_role == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    } else {
      // TODO: 店舗ダッシュボード等へ遷移させる（今はログイン画面に戻す）
      return const StoreDetailScreen();
    }
  }
}
