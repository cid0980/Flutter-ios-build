import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../firebase/catalog_firebase.dart';

/// Push notifications for order status changes.
///
/// The token is minted by the app's **default** Firebase app, which is
/// `french-mobiles-marketplace` — the same project that holds `orders` and
/// runs the notifying function. That matters: firebase_messaging on Android
/// binds to the default app and cannot be pointed elsewhere, so if the
/// default were the owner's stock project instead, every send would fail with
/// SenderId mismatch. See lib/firebase/second_hand_firebase.dart for why the
/// default is the way round it is.
///
/// Tokens are stored as an **array** on `users/{uid}.fcmTokens`, where
/// functions/index.js reads them. An array rather than a single field because
/// a token identifies a *handset*, not an account: someone signed in on a
/// phone and a tablet has two, and a single field meant whichever opened the
/// app last silently stole the notifications from the other.
class OrderNotifications {
  OrderNotifications._();

  static const _channelId = 'order_updates';

  static final _local = FlutterLocalNotificationsPlugin();

  /// Set when a notification was tapped, for whoever can act on it.
  static final ValueNotifier<String?> tappedOrderId =
      ValueNotifier<String?>(null);

  static bool _started = false;

  /// Called once the user is signed in, because the token is stored against
  /// their account. Safe to call again on every sign-in.
  static Future<void> start() async {
    if (_started) {
      await _saveToken();
      return;
    }
    _started = true;

    try {
      await _createChannel();

      // Android 13 and up needs this asked for explicitly; older versions
      // grant it at install and return authorized straight away.
      await FirebaseMessaging.instance.requestPermission();

      await _saveToken();

      // A token is not forever: it rotates when the app is restored to a new
      // device, or data is cleared. Missing this is why notifications quietly
      // stop working months later.
      FirebaseMessaging.instance.onTokenRefresh.listen((token) {
        _writeToken(token);
      });

      // A push arriving while the app is open does not raise a notification
      // on its own — Android suppresses that. Raised here instead, so the
      // seller sees it whatever they happen to be doing.
      FirebaseMessaging.onMessage.listen(_showLocal);

      FirebaseMessaging.onMessageOpenedApp.listen((message) {
        tappedOrderId.value = message.data['orderId'] as String?;
      });

      // Opened from cold, by tapping the notification.
      final initial = await FirebaseMessaging.instance.getInitialMessage();
      if (initial != null) {
        tappedOrderId.value = initial.data['orderId'] as String?;
      }
    } catch (error) {
      // No Play Services, no network, permission refused. The app works
      // without notifications and the orders screen still updates live.
      debugPrint('Order notifications unavailable: $error');
    }
  }

  /// Forgets *this device's* token, leaving the user's other devices alone.
  ///
  /// Called on sign-out, and it matters: the token belongs to the phone, not
  /// the account. Left behind, the next person to sign in on this handset
  /// would receive the previous seller's order updates. Equally, removing the
  /// whole array would silence their other devices, which never signed out.
  static Future<void> stop() async {
    final uid = catalogAuth.currentUser?.uid;
    if (uid == null) return;
    try {
      final token = await FirebaseMessaging.instance.getToken();
      await catalogFirestore.collection('users').doc(uid).set({
        if (token != null) 'fcmTokens': FieldValue.arrayRemove([token]),
        // The old single-token field, cleared on the way past so a stale
        // value cannot outlive the migration.
        'fcmToken': FieldValue.delete(),
      }, SetOptions(merge: true));
    } catch (error) {
      debugPrint('Could not clear the notification token: $error');
    }
  }

  static Future<void> _saveToken() async {
    final token = await FirebaseMessaging.instance.getToken();
    if (token != null) await _writeToken(token);
  }

  static Future<void> _writeToken(String token) async {
    final uid = catalogAuth.currentUser?.uid;
    if (uid == null) return;
    try {
      // arrayUnion rather than a plain write: adding this handset must not
      // disturb the user's other devices, and re-adding one already there is
      // a no-op rather than a duplicate.
      await catalogFirestore.collection('users').doc(uid).set({
        'fcmTokens': FieldValue.arrayUnion([token]),
        'fcmToken': FieldValue.delete(),
      }, SetOptions(merge: true));
    } catch (error) {
      debugPrint('Could not store the notification token: $error');
    }
  }

  static Future<void> _createChannel() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings();
    await _local.initialize(
      const InitializationSettings(android: android, iOS: ios),
      onDidReceiveNotificationResponse: (response) {
        tappedOrderId.value = response.payload;
      },
    );

    // Declared up front so the first notification does not land in a
    // default channel the user cannot then configure.
    const channel = AndroidNotificationChannel(
      _channelId,
      'Order updates',
      description: 'When your order is assigned, inspected or paid.',
      importance: Importance.high,
    );
    await _local
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
  }

  static Future<void> _showLocal(RemoteMessage message) async {
    final notification = message.notification;
    if (notification == null) return;

    await _local.show(
      // Keyed on the order so a later update replaces the earlier one
      // rather than stacking four notifications for the same sale.
      (message.data['orderId'] ?? '').hashCode,
      notification.title,
      notification.body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          'Order updates',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: message.data['orderId'] as String?,
    );
  }
}
