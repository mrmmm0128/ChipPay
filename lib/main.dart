import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:yourpay/admin/admin_dashboard_screen.dart';
import 'package:yourpay/admin/admin_login_screen.dart';
import 'package:yourpay/admin/admin_tenant_detrail_screen.dart';
import 'package:yourpay/endUser/tip_complete_page.dart';
import 'package:yourpay/tenant/account_detail_screen.dart';
import 'package:yourpay/endUser/public_store_page.dart';
import 'package:yourpay/endUser/staff_detail_page.dart';
import 'package:yourpay/tenant/public_staff_qr_list_page.dart';
import 'package:yourpay/tenant/qr_poster_build_page.dart';
import 'package:yourpay/tenant/store_admin_add/accept_invite_screen.dart';
import 'package:yourpay/tenant/store_list_screen.dart';
import 'tenant/login_screens.dart';
import 'tenant/store_detail_screen.dart';
import 'tenant/admin_console_screen.dart';
import 'endUser/payer_landing_screen.dart';

// TODO: 生成した Firebase 設定に置き換え
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
  await Firebase.initializeApp(options: firebaseOptions);
  //await connectToEmulatorsIfDebug(); // ← 追加
  runApp(const MyApp());
}

Future<void> connectToEmulatorsIfDebug() async {
  if (kDebugMode) {
    // Webは localhost でも OK
    FirebaseFirestore.instance.useFirestoreEmulator('localhost', 8080);
    FirebaseFunctions.instance.useFunctionsEmulator('localhost', 5001);
    // Auth を使うなら（任意）
    await FirebaseAuth.instance.useAuthEmulator('localhost', 9099);
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final Map<String, WidgetBuilder> appRoutes = {
      '/': (_) => const Root(),
      '/login': (_) => const LoginScreen(),
      '/stores': (_) => const StoreListScreen(),
      '/store': (_) => const StoreDetailScreen(),
      '/p': (_) => const PublicStorePage(), // 公開
      '/staff': (_) => const StaffDetailPage(), // 公開
      '/chechout-end': (_) => const TipCompletePage(tenantId: ''), // 公開
      '/account': (_) => const AccountDetailScreen(),
      '/admin-login': (_) => const AdminLoginScreen(),
      '/admin': (_) => const AdminDashboardScreen(),
      '/admin/tenant': (_) => const AdminTenantDetailScreen(),
      '/admin-invite': (_) => const AcceptInviteScreen(),
      '/qr-all': (_) => const PublicStaffQrListPage(), // 公開
      '/qr-builder': (_) => const QrPosterBuilderPage(), // 公開
    };

    return MaterialApp(
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        textTheme: ThemeData.dark().textTheme.apply(
          bodyColor: Colors.black, // 本文の色
          displayColor: Colors.black, // 見出しの色
        ),
      ),

      onGenerateRoute: (settings) {
        final name = settings.name ?? '/';
        final uri = Uri.parse(name);

        // クエリ付きを個別処理
        if (uri.path == '/payer') {
          final sid = uri.queryParameters['sid'] ?? '';
          return MaterialPageRoute(
            builder: (_) => PayerLandingScreen(sessionId: sid),
            settings: settings,
          );
        }

        if (uri.path == '/p') {
          final tid = uri.queryParameters['t'] ?? '';
          final thanks = uri.queryParameters['thanks'] == 'true';
          final canceled = uri.queryParameters['canceled'] == 'true';

          // 成功/キャンセル時は完了ページへ
          if (thanks || canceled) {
            return MaterialPageRoute(
              builder: (_) => TipCompletePage(
                tenantId: tid,
                // これらはURLに載せていなければnullでOK（ページ内で再読込されます）
                tenantName: uri.queryParameters['tenantName'],
                amount: int.tryParse(uri.queryParameters['amount'] ?? ''),
                employeeName: uri.queryParameters['employeeName'],
              ),
              settings: settings,
            );
          }

          // 通常表示（公開ストアページ）
          return MaterialPageRoute(
            builder: (_) => const PublicStorePage(),
            settings: RouteSettings(
              name: settings.name,
              arguments: {'tenantId': tid},
            ),
          );
        }

        if (uri.path == '/staff') {
          return MaterialPageRoute(
            builder: (_) => const StaffDetailPage(),
            settings: RouteSettings(
              name: settings.name,
              arguments: {
                'tenantId': uri.queryParameters['tid'],
                'employeeId': uri.queryParameters['eid'],
              },
            ),
          );
        }

        // ✅ 公開ルートもここで必ず解決（null返し禁止）
        final builder = appRoutes[uri.path];
        if (builder != null) {
          return MaterialPageRoute(builder: builder, settings: settings);
        }

        // 未知はログインへ（404を作るならそちらへ）
        return MaterialPageRoute(
          builder: (_) => const LoginScreen(),
          settings: settings,
        );
      },

      // pushNamed 用
      routes: appRoutes,
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

        // いまのURLからパス部分だけ取り出す（/#/qr-all?… → /qr-all）
        String currentPath() {
          final uri = Uri.base;
          if (uri.fragment.isNotEmpty) {
            final frag = uri.fragment; // "/qr-all?t=xxx"
            final q = frag.indexOf('?');
            return q >= 0 ? frag.substring(0, q) : frag; // "/qr-all"
          }
          return uri.path; // "/qr-all"
        }

        final path = currentPath();
        final publicPaths = const {'/qr-all', '/qr-builder', '/staff', '/p'};

        // 未ログインでも公開ページはそのまま表示
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

        // 未ログイン & 非公開ページ → ログイン
        if (snap.data == null) return const LoginScreen();

        // ログイン済み → 従来の管理シェルへ
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
    setState(() {
      _role = (result.claims?['role'] as String?) ?? 'staff';
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_role == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_role == 'superadmin') {
      return const AdminConsoleScreen();
    } else {
      //return const LoginScreen();
      return const LoginScreen();
    }
  }
}
