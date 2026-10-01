import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'firebase/catalog_firebase.dart';
import 'firebase/second_hand_firebase.dart';
import 'shared/services/order_notifications.dart';
import 'features/shell/main_shell.dart';
import 'shared/theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Edge-to-edge and the hiding of the navigation bar are both set natively
  // in MainActivity. Asking for SystemUiMode.edgeToEdge here would explicitly
  // show every system bar and undo that hide on startup.
  //
  // Only the status bar's appearance is set from Dart, because it stays.
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    statusBarBrightness: Brightness.light,
  ));

  try {
    await Firebase.initializeApp(options: catalogFirebaseOptions);
  } catch (_) {
    // Firebase unavailable (e.g. missing web config); app still renders.
  }
  try {
    await initializeCatalogApp();
  } catch (_) {
    // Secondary app failed to init; fall back to the default app.
  }
  try {
    await initializeSecondHandApp();
  } catch (_) {
    // The owner's stock project is unreachable; the home screen shows an
    // empty listings row rather than failing the whole app.
  }
  try {
    const oauthClientId =
        '1086357315686-gd3cjbuqqll9umc7peffkd04laiq6hmt.apps.googleusercontent.com';
    await GoogleSignIn.instance.initialize(
      clientId:
          defaultTargetPlatform == TargetPlatform.iOS ? oauthClientId : null,
      serverClientId: oauthClientId,
    );
  } catch (_) {
    // Google Sign-In unavailable; app still renders.
  }

  // Registers this device for order updates whenever somebody signs in.
  //
  // Watched here rather than on a page, because it has to happen once for the
  // whole app and must survive whichever screen the sign-in happened on.
  // Signing *out* is handled at the sign-out button instead: by the time this
  // listener sees a null user the uid is already gone, and the token is
  // stored against the uid.
  try {
    catalogAuth.authStateChanges().listen((user) {
      if (user != null) OrderNotifications.start();
    });
  } catch (_) {
    // Auth unavailable; the app still renders and orders still update live.
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key, this.home});

  /// Replaces the home screen.
  ///
  /// Only for tests: the real one reads Firebase on its first frame, so the
  /// app shell cannot otherwise be built without it.
  @visibleForTesting
  final Widget? home;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Trade-In App Flow',
      // The design system, applied once. Screens used to wrap themselves in
      // AppTheme.light individually because MaterialApp still carried the
      // original inline theme; those wrappers are now redundant rather than
      // load-bearing, and the screens that never had one — the checkup
      // flow — stop inheriting black-on-green buttons and a white page.
      theme: AppTheme.light,
      home: home ?? const MainShell(),
    );
  }
}
