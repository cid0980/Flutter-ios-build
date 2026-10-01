// The marketplace project, reached through a *named* app.
//
// It is also the default app now (android/app/google-services.json), so
// `catalogFirestore` and `FirebaseFirestore.instance` point at the same
// project. The named app is kept anyway: firebase_auth persists a session per
// FirebaseApp name, so collapsing this into the default would sign out
// everyone who is signed in today. Leave it alone.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';

const FirebaseOptions catalogFirebaseOptions = FirebaseOptions(
  apiKey: 'AIzaSyCV6pjsYpstL1sKCcPgemIEt6iAjZw-dBg',
  appId: '1:1086357315686:android:1f43282812dc89095c4da7',
  messagingSenderId: '1086357315686',
  projectId: 'french-mobiles-marketplace',
  storageBucket: 'french-mobiles-marketplace.firebasestorage.app',
  iosBundleId: 'com.example.frenchMobiles',
);

Future<void> initializeCatalogApp() async {
  await Firebase.initializeApp(
    name: 'catalogApp',
    options: catalogFirebaseOptions,
  );
}

FirebaseApp get catalogApp {
  try {
    return Firebase.app('catalogApp');
  } catch (_) {
    return Firebase.app();
  }
}

FirebaseFirestore get catalogFirestore =>
    FirebaseFirestore.instanceFor(app: catalogApp);

FirebaseAuth get catalogAuth =>
  FirebaseAuth.instanceFor(app: catalogApp);
