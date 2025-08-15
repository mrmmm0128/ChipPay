import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:yourpay/StoreListScreen.dart';
import 'screens/Login_screens.dart';
import 'screens/store_dashboard_screen.dart';
import 'screens/admin_console_screen.dart';
import 'screens/payer_landing_screen.dart';

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
    return MaterialApp(
      title: 'YourPay',
      theme: ThemeData.dark(useMaterial3: true),
      onGenerateRoute: (settings) {
        // /payer?sid=cs_test_xxx のようなURLを想定
        if (settings.name?.startsWith('/payer') == true) {
          final uri = Uri.parse(settings.name!);
          final sid = uri.queryParameters['sid'] ?? '';
          return MaterialPageRoute(
            builder: (_) => PayerLandingScreen(sessionId: sid),
          );
        }
        return null;
      },
      routes: {
        '/': (_) => const Root(),
        '/login': (_) => const LoginScreen(),
        '/stores': (_) => const StoreListScreen(),
        '/store': (_) => const StoreDashboardScreen(),
        '/admin': (_) => const AdminConsoleScreen(),
      },
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
        if (snap.data == null) return const LoginScreen();
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
      return const StoreDashboardScreen();
    }
  }
}
