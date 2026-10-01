import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';

/// The owner's second-hand stock, which lives in a different Firebase project.
///
/// `fren-75087` is not this app's backend — it is a separate, live product
/// where the owner lists second-hand handsets through their own web app. This
/// app only ever **reads** `second_hand_mobiles` from it, to show that stock
/// on the home screen and in Saved. The owner's site remains the only writer,
/// so the data is never copied here: a copy would fork the moment they added
/// a phone.
///
/// Reached through a named secondary app rather than the default one. The
/// default is `french-mobiles-marketplace` — this app's own backend, and the
/// project that mints the push token, which is the reason round for this
/// arrangement. See `catalog_firebase.dart`.
const FirebaseOptions secondHandFirebaseOptions = FirebaseOptions(
  apiKey: 'AIzaSyDvw7e_CddKBj3edgx4_PV_rBvKy9vBn6U',
  appId: '1:530574210824:android:98160269e3fe051fb89ebd',
  messagingSenderId: '530574210824',
  projectId: 'fren-75087',
  storageBucket: 'fren-75087.firebasestorage.app',
  iosBundleId: 'com.example.frenchMobiles',
);

Future<void> initializeSecondHandApp() async {
  try {
    Firebase.app('secondHandApp');
  } on FirebaseException {
    await Firebase.initializeApp(
      name: 'secondHandApp',
      options: secondHandFirebaseOptions,
    );
  }
}

FirebaseApp get secondHandApp => Firebase.app('secondHandApp');

/// The stock listings, read-only.
FirebaseFirestore get secondHandFirestore =>
    FirebaseFirestore.instanceFor(app: secondHandApp);
