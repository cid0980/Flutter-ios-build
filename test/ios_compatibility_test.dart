import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:french_mobiles/models/checkup_result.dart';
import 'package:french_mobiles/screens/biometric_diagnostic_page.dart';
import 'package:french_mobiles/screens/checkup/battery_test_page.dart';
import 'package:french_mobiles/screens/checkup/bluetooth_test_page.dart';
import 'package:french_mobiles/screens/checkup/buttons_test_page.dart';
import 'package:french_mobiles/screens/checkup/checkup_permissions.dart';
import 'package:french_mobiles/screens/checkup/earpiece_test_page.dart';
import 'package:french_mobiles/screens/checkup/internet_test_page.dart';
import 'package:french_mobiles/screens/checkup/network_test_page.dart';
import 'package:french_mobiles/screens/checkup/wifi_test_page.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  group('iOS Native Configuration & Channel Parity', () {
    test('Info.plist contains all required iOS privacy descriptions and keys',
        () {
      final plist = File('ios/Runner/Info.plist').readAsStringSync();

      const requiredKeys = <String>[
        'NSCameraUsageDescription',
        'NSMicrophoneUsageDescription',
        'NSFaceIDUsageDescription',
        'NSLocationWhenInUseUsageDescription',
        'NSLocationAlwaysAndWhenInUseUsageDescription',
        'NSBluetoothAlwaysUsageDescription',
        'NSBluetoothPeripheralUsageDescription',
        'NSMotionUsageDescription',
        'NSPhotoLibraryUsageDescription',
        'NSPhotoLibraryAddUsageDescription',
        'NSLocalNetworkUsageDescription',
        'GIDClientID',
        'CFBundleURLSchemes',
        'UIBackgroundModes',
      ];

      for (final key in requiredKeys) {
        expect(
          plist.contains('<key>$key</key>'),
          isTrue,
          reason: 'Missing $key in ios/Runner/Info.plist',
        );
      }
    });

    test('Podfile enables required permission_handler_apple preprocessor flags',
        () {
      final podfile = File('ios/Podfile').readAsStringSync();

      const requiredFlags = <String>[
        'PERMISSION_CAMERA=1',
        'PERMISSION_MICROPHONE=1',
        'PERMISSION_LOCATION=1',
        'PERMISSION_LOCATION_WHENINUSE=1',
        'PERMISSION_BLUETOOTH=1',
        'PERMISSION_SENSORS=1',
        'PERMISSION_NOTIFICATIONS=1',
        'PERMISSION_PHOTOS=1',
      ];

      for (final flag in requiredFlags) {
        expect(
          podfile.contains(flag),
          isTrue,
          reason: 'Missing $flag in ios/Podfile',
        );
      }
      expect(podfile.contains('use_frameworks! :linkage => :static'), isTrue);

      final debugXcconfig =
          File('ios/Flutter/Debug.xcconfig').readAsStringSync();
      final releaseXcconfig =
          File('ios/Flutter/Release.xcconfig').readAsStringSync();
      expect(
        debugXcconfig
            .contains('Pods/Target Support Files/Pods-Runner/Pods-Runner.debug.xcconfig'),
        isTrue,
      );
      expect(
        releaseXcconfig.contains(
            'Pods/Target Support Files/Pods-Runner/Pods-Runner.release.xcconfig'),
        isTrue,
      );
    });

    test(
        'AppDelegate.swift registers all 9 native channels & Google Maps init for iOS',
        () {
      final swift = File('ios/Runner/AppDelegate.swift').readAsStringSync();

      const requiredChannels = <String>[
        'french_mobiles/volume_keys',
        'french_mobiles/audio_route',
        'french_mobiles/battery',
        'french_mobiles/thermal',
        'french_mobiles/proximity_screen',
        'french_mobiles/power_button',
        'french_mobiles/internet',
        'com.vincentkammerer.sim_data/channel_name',
        'fingerprint_test/methods',
        'fingerprint_test/events',
      ];

      for (final channel in requiredChannels) {
        expect(
          swift.contains('"$channel"'),
          isTrue,
          reason: 'Missing channel "$channel" in ios/Runner/AppDelegate.swift',
        );
      }

      expect(swift.contains('didInitializeImplicitFlutterEngine'), isTrue);
      expect(swift.contains('probeCellular'), isTrue);
      expect(swift.contains('probeWifi'), isTrue);
      expect(swift.contains('getSimData'), isTrue);
      expect(swift.contains('GMSServices'), isTrue);
    });
  });

  group('iOS Auto Checkup Runtime Behavior', () {
    const permissionChannel =
        MethodChannel('flutter.baseflow.com/permissions/methods');
    const internetChannel = MethodChannel('french_mobiles/internet');
    const simDataChannel =
        MethodChannel('com.vincentkammerer.sim_data/channel_name');
    const connectivityChannel =
        MethodChannel('dev.fluttercommunity.plus/connectivity');
    const volumeChannel = MethodChannel('french_mobiles/volume_keys');
    const powerChannel = MethodChannel('french_mobiles/power_button');
    const audioRouteChannel = MethodChannel('french_mobiles/audio_route');
    const batteryChannel = MethodChannel('french_mobiles/battery');

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(permissionChannel, null);
      messenger.setMockMethodCallHandler(internetChannel, null);
      messenger.setMockMethodCallHandler(simDataChannel, null);
      messenger.setMockMethodCallHandler(connectivityChannel, null);
      messenger.setMockMethodCallHandler(volumeChannel, null);
      messenger.setMockMethodCallHandler(powerChannel, null);
      messenger.setMockMethodCallHandler(audioRouteChannel, null);
      messenger.setMockMethodCallHandler(batteryChannel, null);
    });

    test(
        'CheckupPermissions filters out Android-only permissions on iOS and uses Permission.bluetooth',
        () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        final requestedPermissions = <int>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(permissionChannel, (call) async {
          if (call.method == 'checkPermissionStatus') {
            return 0; // denied (so it appears in outstanding)
          }
          if (call.method == 'requestPermissions') {
            final list = (call.arguments as List).cast<int>();
            requestedPermissions.addAll(list);
            return <int, int>{for (final p in list) p: 1};
          }
          return null;
        });

        final outstanding = await CheckupPermissions.outstanding();
        final perms = outstanding.map((n) => n.permission).toList();

        expect(perms, contains(Permission.camera));
        expect(perms, contains(Permission.microphone));
        expect(perms, contains(Permission.location));
        expect(perms, contains(Permission.bluetooth));
        expect(perms, isNot(contains(Permission.nearbyWifiDevices)));
        expect(perms, isNot(contains(Permission.phone)));
        expect(perms, isNot(contains(Permission.bluetoothScan)));
        expect(perms, isNot(contains(Permission.bluetoothConnect)));

        await CheckupPermissions.requestAll();
        expect(
          requestedPermissions,
          containsAll(<int>[
            Permission.camera.value,
            Permission.microphone.value,
            Permission.location.value,
            Permission.bluetooth.value,
          ]),
        );
        expect(
          requestedPermissions,
          isNot(contains(Permission.nearbyWifiDevices.value)),
        );
        expect(requestedPermissions, isNot(contains(Permission.phone.value)));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets(
        'WifiTestPage uses native probeWifi on iOS and passes when Wi-Fi is active',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        var probeWifiCalled = false;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(internetChannel, (call) async {
          if (call.method == 'probeWifi') {
            probeWifiCalled = true;
            return <String, dynamic>{
              'status': 'ok',
              'code': 204,
              'ms': 38,
            };
          }
          return null;
        });

        CheckupResult? result;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: ElevatedButton(
                  onPressed: () async {
                    result = await Navigator.of(context).push<CheckupResult>(
                      MaterialPageRoute(builder: (_) => const WifiTestPage()),
                    );
                  },
                  child: const Text('Run Wi-Fi'),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Run Wi-Fi'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump(const Duration(milliseconds: 1600));
        await tester.pumpAndSettle();

        expect(probeWifiCalled, isTrue);
        expect(result, isNotNull);
        expect(result!.status, CheckupStatus.pass);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets(
        'NetworkTestPage reads iOS SIM / cellular state without Android phone permission',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        var simDataCalled = false;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(simDataChannel, (call) async {
          if (call.method == 'getSimData') {
            simDataCalled = true;
            return jsonEncode({
              'cards': [
                {
                  'carrierName': 'Jio True5G',
                  'displayName': 'Jio True5G',
                  'countryCode': 'in',
                  'mcc': 405,
                  'mnc': 869,
                  'isDataRoaming': false,
                  'isNetworkRoaming': false,
                  'slotIndex': 0,
                  'serialNumber': 'ios-sim-0',
                  'subscriptionId': 0,
                  'phoneNumber': '',
                }
              ],
            });
          }
          return null;
        });

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(connectivityChannel, (call) async {
          if (call.method == 'check') {
            return <String>['mobile'];
          }
          return null;
        });

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(internetChannel, (call) async {
          if (call.method == 'probeCellular') {
            return <String, dynamic>{
              'status': 'ok',
              'code': 204,
              'ms': 45,
            };
          }
          return null;
        });

        CheckupResult? result;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: ElevatedButton(
                  onPressed: () async {
                    result = await Navigator.of(context).push<CheckupResult>(
                      MaterialPageRoute(
                          builder: (_) => const NetworkTestPage()),
                    );
                  },
                  child: const Text('Run Network'),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Run Network'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump(const Duration(milliseconds: 1600));
        await tester.pumpAndSettle();

        expect(simDataCalled, isTrue);
        expect(result, isNotNull);
        expect(result!.status, CheckupStatus.pass);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets(
        'InternetTestPage verifies both cellular and Wi-Fi routes over native iOS channel',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(simDataChannel, (call) async {
          if (call.method == 'getSimData') {
            return jsonEncode({
              'cards': [
                {
                  'carrierName': 'Airtel',
                  'displayName': 'Airtel',
                  'countryCode': 'in',
                  'mcc': 404,
                  'mnc': 45,
                  'isDataRoaming': false,
                  'isNetworkRoaming': false,
                  'slotIndex': 0,
                  'serialNumber': 'ios-sim-0',
                  'subscriptionId': 0,
                  'phoneNumber': '',
                }
              ],
            });
          }
          return null;
        });

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(connectivityChannel, (call) async {
          if (call.method == 'check') {
            return <String>['wifi', 'mobile'];
          }
          return null;
        });

        var cellularProbed = false;
        var wifiProbed = false;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(internetChannel, (call) async {
          if (call.method == 'probeCellular') {
            cellularProbed = true;
            return <String, dynamic>{'status': 'ok', 'code': 204, 'ms': 52};
          }
          if (call.method == 'probeWifi') {
            wifiProbed = true;
            return <String, dynamic>{'status': 'ok', 'code': 204, 'ms': 19};
          }
          return null;
        });

        CheckupResult? result;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: ElevatedButton(
                  onPressed: () async {
                    result = await Navigator.of(context).push<CheckupResult>(
                      MaterialPageRoute(
                          builder: (_) => const InternetTestPage()),
                    );
                  },
                  child: const Text('Run Internet'),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Run Internet'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump(const Duration(milliseconds: 1600));
        await tester.pumpAndSettle();

        expect(cellularProbed, isTrue);
        expect(wifiProbed, isTrue);
        expect(result, isNotNull);
        expect(result!.status, CheckupStatus.pass);
        expect(result!.detail, contains('Mobile data reaches the internet'));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets(
        'ButtonsTestPage detects Volume Down, Volume Up, and Side/Power button events on iOS',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        var volumeListeningEnabled = false;
        var powerWatchingStarted = false;
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

        messenger.setMockMethodCallHandler(volumeChannel, (call) async {
          if (call.method == 'setVolumeListening') {
            final args = call.arguments as Map?;
            volumeListeningEnabled = args?['enabled'] == true;
          }
          return null;
        });

        messenger.setMockMethodCallHandler(powerChannel, (call) async {
          if (call.method == 'startWatching') {
            powerWatchingStarted = true;
            return true;
          }
          if (call.method == 'stopWatching') {
            return true;
          }
          return null;
        });

        CheckupResult? result;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: ElevatedButton(
                  onPressed: () async {
                    result = await Navigator.of(context).push<CheckupResult>(
                      MaterialPageRoute(
                          builder: (_) => const ButtonsTestPage()),
                    );
                  },
                  child: const Text('Run Buttons'),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Run Buttons'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(volumeListeningEnabled, isTrue);

        // Step 1: Volume Down (unawaited because _onMethodCall awaits a 400ms
        // FakeAsync timer that advances on tester.pump).
        unawaited(messenger.handlePlatformMessage(
          volumeChannel.name,
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall('volumeKey', {'key': 'volume_down'}),
          ),
          (_) {},
        ));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));

        // Step 2: Volume Up
        unawaited(messenger.handlePlatformMessage(
          volumeChannel.name,
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall('volumeKey', {'key': 'volume_up'}),
          ),
          (_) {},
        ));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(powerWatchingStarted, isTrue);

        // Step 3: Power / Side button (screen_off -> screen_on)
        unawaited(messenger.handlePlatformMessage(
          powerChannel.name,
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall('screenEvent', {'event': 'screen_off'}),
          ),
          (_) {},
        ));
        await tester.pump(const Duration(milliseconds: 100));

        unawaited(messenger.handlePlatformMessage(
          powerChannel.name,
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall('screenEvent', {'event': 'screen_on'}),
          ),
          (_) {},
        ));
        await tester.pump();
        await tester.pumpAndSettle();

        expect(result, isNotNull);
        expect(result!.status, CheckupStatus.pass);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets(
        'EarpieceTestPage marks notAvailable when iOS device has no earpiece (iPad)',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(audioRouteChannel, (call) async {
          if (call.method == 'hasEarpiece') return false;
          return null;
        });

        CheckupResult? result;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: ElevatedButton(
                  onPressed: () async {
                    result = await Navigator.of(context).push<CheckupResult>(
                      MaterialPageRoute(
                          builder: (_) => const EarpieceTestPage()),
                    );
                  },
                  child: const Text('Run Earpiece'),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Run Earpiece'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump(const Duration(milliseconds: 1600));
        await tester.pumpAndSettle();

        expect(result, isNotNull);
        expect(result!.status, CheckupStatus.notAvailable);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets(
        'BatteryTestPage reads iOS battery state and shows iOS-specific health instructions',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        var batteryReadCalled = false;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(batteryChannel, (call) async {
          if (call.method == 'read') {
            batteryReadCalled = true;
            return <String, dynamic>{
              'present': true,
              'level': 88,
              'charging': true,
              'powerSource': 'mains',
              'healthFlag': 'good',
              'technology': 'Li-ion',
              'sdkInt': 18,
            };
          }
          return null;
        });

        CheckupResult? result;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: ElevatedButton(
                  onPressed: () async {
                    result = await Navigator.of(context).push<CheckupResult>(
                      MaterialPageRoute(
                          builder: (_) => const BatteryTestPage()),
                    );
                  },
                  child: const Text('Run Battery'),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Run Battery'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump(const Duration(milliseconds: 1600));
        await tester.pumpAndSettle();

        expect(batteryReadCalled, isTrue);
        expect(result, isNotNull);
        expect(result!.status, CheckupStatus.notAvailable);
        expect(result!.detail, contains('Settings → Battery'));
        expect(result!.detail, contains('88% charged'));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets(
        'BluetoothTestPage requests Permission.bluetooth on iOS instead of Android bluetoothScan/Connect',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        final requestedPermissions = <int>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(permissionChannel, (call) async {
          if (call.method == 'requestPermissions') {
            final list = (call.arguments as List).cast<int>();
            requestedPermissions.addAll(list);
            return <int, int>{for (final p in list) p: 0}; // denied -> skipped
          }
          return 0;
        });

        CheckupResult? result;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: ElevatedButton(
                  onPressed: () async {
                    result = await Navigator.of(context).push<CheckupResult>(
                      MaterialPageRoute(
                          builder: (_) => const BluetoothTestPage()),
                    );
                  },
                  child: const Text('Run Bluetooth'),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Run Bluetooth'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump(const Duration(milliseconds: 1600));
        await tester.pumpAndSettle();

        expect(requestedPermissions, contains(Permission.bluetooth.value));
        expect(
          requestedPermissions,
          isNot(contains(Permission.bluetoothScan.value)),
        );
        expect(
          requestedPermissions,
          isNot(contains(Permission.bluetoothConnect.value)),
        );
        expect(result, isNotNull);
        expect(result!.status, CheckupStatus.skipped);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('BiometricDiagnosticPage (Reverse-engineering-data-s integration)', () {
    const methodChannel = MethodChannel('fingerprint_test/methods');
    const eventChannel = MethodChannel('fingerprint_test/events');

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(eventChannel, null);
    });

    testWidgets(
        'renders iOS Face ID / Touch ID status, starts native biometric diagnostic, and handles auth_succeeded event',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        final invokedMethods = <String>[];
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

        messenger.setMockMethodCallHandler(methodChannel, (call) async {
          invokedMethods.add(call.method);
          if (call.method == 'getStatus') {
            return <String, dynamic>{
              'sdkInt': 18,
              'biometryType': 'Face ID',
              'supported': true,
              'permissionGranted': true,
              'hasHardware': true,
              'hasEnrolled': true,
              'ready': true,
              'listening': false,
            };
          }
          if (call.method == 'startAuth') {
            return true;
          }
          return null;
        });

        messenger.setMockMethodCallHandler(eventChannel, (call) async => null);

        bool? diagnosticResult;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: ElevatedButton(
                  onPressed: () async {
                    diagnosticResult = await Navigator.of(context).push<bool>(
                      MaterialPageRoute(
                        builder: (_) => const BiometricDiagnosticPage(),
                      ),
                    );
                  },
                  child: const Text('Open Diagnostic'),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Open Diagnostic'));
        await tester.pumpAndSettle();

        expect(invokedMethods, contains('getStatus'));
        expect(find.text('Face ID Diagnostic'), findsOneWidget);
        expect(find.text('Face ID'), findsOneWidget);
        expect(find.text('Start Listening'), findsOneWidget);

        await tester.tap(find.text('Start Listening'));
        await tester.pump();
        expect(invokedMethods, contains('startAuth'));

        // Simulate native iOS LocalAuthentication sending auth_succeeded event
        await messenger.handlePlatformMessage(
          eventChannel.name,
          const StandardMethodCodec().encodeSuccessEnvelope(<String, dynamic>{
            'type': 'auth_succeeded',
            'detail': 'Face ID verified!',
            'timestamp': 1700000000000,
          }),
          (_) {},
        );
        await tester.pumpAndSettle();

        expect(find.text('PASS: Face ID verified!'), findsOneWidget);
        expect(find.text('Done'), findsOneWidget);

        await tester.tap(find.text('Done'));
        await tester.pumpAndSettle();

        expect(diagnosticResult, isTrue);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
