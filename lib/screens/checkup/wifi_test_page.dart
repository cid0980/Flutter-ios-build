import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wifi_scan/wifi_scan.dart';

import '../../models/checkup_result.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/theme/app_text_styles.dart';
import 'checkup_demo.dart';
import 'checkup_test_shell.dart';

/// Test 4 — Wi-Fi.
///
/// Requests the permissions Wi-Fi scanning needs, raises Android's own
/// "Turn on location?" dialog if location services are off, then performs a
/// scan. Passes when at least one nearby network is found. Auto-advances.
class WifiTestPage extends StatefulWidget {
  const WifiTestPage({super.key});

  @override
  State<WifiTestPage> createState() => _WifiTestPageState();
}

class _WifiTestPageState extends State<WifiTestPage> {
  static const _internetChannel = MethodChannel('french_mobiles/internet');

  final List<WiFiAccessPoint> _networks = [];
  bool _scanning = false;
  bool _isPermanentlyDenied = false;

  /// Location services were off and the user dismissed Android's dialog.
  /// Unlike a permanently denied permission this is one tap from being fixed,
  /// so the verdict offers the dialog again instead of ending the test.
  bool _locationServicesOff = false;

  String _statusText = 'Preparing Wi-Fi scan…';
  CheckupResult? _result;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    if (!mounted) return;
    setState(() {
      _scanning = true;
      _statusText = 'Checking Wi-Fi permissions…';
    });

    if (defaultTargetPlatform == TargetPlatform.iOS) {
      await _runIOSWifiCheck();
      return;
    }

    final nearby = await Permission.nearbyWifiDevices.request();
    if (!mounted) return;
    if (nearby.isPermanentlyDenied) {
      setState(() => _isPermanentlyDenied = true);
      _setResult(
          const CheckupResult(
            key: 'wifi',
            title: 'Wi-Fi',
            status: CheckupStatus.skipped,
            detail:
                'Nearby Wi-Fi permission is permanently denied. Open Settings to grant.',
          ),
          hold: true);
      return;
    }
    if (!nearby.isGranted) {
      _setResult(const CheckupResult(
        key: 'wifi',
        title: 'Wi-Fi',
        status: CheckupStatus.skipped,
        detail: 'Nearby device (Wi-Fi) permission was denied.',
      ));
      return;
    }

    final location = await Permission.location.request();
    if (!mounted) return;
    if (location.isPermanentlyDenied) {
      setState(() => _isPermanentlyDenied = true);
      _setResult(
          const CheckupResult(
            key: 'wifi',
            title: 'Wi-Fi',
            status: CheckupStatus.skipped,
            detail:
                'Location permission is permanently denied. Open Settings to grant.',
          ),
          hold: true);
      return;
    }
    if (!location.isGranted) {
      _setResult(const CheckupResult(
        key: 'wifi',
        title: 'Wi-Fi',
        status: CheckupStatus.skipped,
        detail:
            'Location permission needed for Wi-Fi scanning was not granted.',
      ));
      return;
    }

    await _ensureLocationServices();
    if (!mounted) return;

    if (!await Geolocator.isLocationServiceEnabled()) {
      if (!mounted) return;
      setState(() => _locationServicesOff = true);
      _setResult(
          const CheckupResult(
            key: 'wifi',
            title: 'Wi-Fi',
            status: CheckupStatus.skipped,
            detail:
                'Location services are switched off — Android requires them to '
                'scan for Wi-Fi.',
          ),
          hold: true);
      return;
    }

    await _startScan();
  }

  /// iOS forbids third-party apps from scanning nearby Wi-Fi SSIDs without a
  /// private HotspotHelper entitlement, so on iOS we verify the Wi-Fi radio by
  /// probing directly over the native `en0` Wi-Fi interface.
  Future<void> _runIOSWifiCheck() async {
    if (!mounted) return;
    setState(() {
      _scanning = true;
      _statusText = 'Verifying Wi-Fi radio and connection…';
    });

    try {
      final probe = await _internetChannel
          .invokeMapMethod<String, dynamic>('probeWifi')
          .timeout(const Duration(seconds: 10));

      if (!mounted) return;
      setState(() => _scanning = false);

      if (probe != null) {
        final status = probe['status'];
        final ms = (probe['ms'] as num?)?.round();
        if (status == 'ok') {
          _setResult(CheckupResult(
            key: 'wifi',
            title: 'Wi-Fi',
            status: CheckupStatus.pass,
            detail:
                'Wi-Fi radio works — connected and verified${ms != null ? ' (${ms}ms)' : ''}',
          ));
          return;
        }
        if (status == 'captive') {
          _setResult(const CheckupResult(
            key: 'wifi',
            title: 'Wi-Fi',
            status: CheckupStatus.pass,
            detail: 'Wi-Fi radio works — connected to a local Wi-Fi network',
          ));
          return;
        }
        if (status == 'no_wifi') {
          _setResult(const CheckupResult(
            key: 'wifi',
            title: 'Wi-Fi',
            status: CheckupStatus.skipped,
            detail:
                'Not connected to Wi-Fi. Connect to a Wi-Fi network in Settings to verify the radio.',
          ));
          return;
        }
      }

      final types = await Connectivity().checkConnectivity();
      if (!mounted) return;
      if (types.contains(ConnectivityResult.wifi)) {
        _setResult(const CheckupResult(
          key: 'wifi',
          title: 'Wi-Fi',
          status: CheckupStatus.pass,
          detail: 'Wi-Fi radio works — connected to Wi-Fi',
        ));
      } else {
        _setResult(const CheckupResult(
          key: 'wifi',
          title: 'Wi-Fi',
          status: CheckupStatus.skipped,
          detail:
              'Not connected to Wi-Fi. Connect to a Wi-Fi network in Settings to verify the radio.',
        ));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _scanning = false);
      _setResult(CheckupResult(
        key: 'wifi',
        title: 'Wi-Fi',
        status: CheckupStatus.fail,
        detail: 'Wi-Fi check failed: $e',
      ));
    }
  }

  /// Raises Android's own "Turn on location?" dialog when location services
  /// are off, and returns once the user has answered it.
  ///
  /// Asking geolocator for a position is what triggers that dialog; there is
  /// no call that asks for it directly. The position is thrown away — a Wi-Fi
  /// scan needs the service switched on, not a fix.
  ///
  /// This page used to call openLocationSettings() instead, which threw the
  /// user out into the system settings app and needed a lifecycle observer to
  /// notice them coming back. The dialog resolves it without leaving.
  Future<void> _ensureLocationServices() async {
    if (await Geolocator.isLocationServiceEnabled()) return;
    if (!mounted) return;

    setState(() => _statusText = 'Waiting for location to be switched on…');
    try {
      await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.lowest,
          timeLimit: Duration(seconds: 10),
        ),
      );
    } catch (_) {
      // Dismissed, or no fix in time. The caller re-checks the service and
      // reports it; either way this is not the scan's verdict.
    }
  }

  Future<void> _startScan() async {
    if (!mounted) return;

    final can = await WiFiScan.instance.canStartScan(askPermissions: true);
    if (!mounted) return;
    switch (can) {
      case CanStartScan.yes:
        break;
      case CanStartScan.noLocationServiceDisabled:
        _setResult(const CheckupResult(
          key: 'wifi',
          title: 'Wi-Fi',
          status: CheckupStatus.skipped,
          detail: 'Location services must be on for a Wi-Fi scan.',
        ));
        return;
      case CanStartScan.noLocationPermissionRequired:
      case CanStartScan.noLocationPermissionDenied:
      case CanStartScan.noLocationPermissionUpgradeAccuracy:
        _setResult(const CheckupResult(
          key: 'wifi',
          title: 'Wi-Fi',
          status: CheckupStatus.skipped,
          detail:
              'Location permission needed for Wi-Fi scanning was not granted.',
        ));
        return;
      case CanStartScan.notSupported:
        _setResult(const CheckupResult(
          key: 'wifi',
          title: 'Wi-Fi',
          status: CheckupStatus.skipped,
          detail: 'Wi-Fi scanning is not supported on this device.',
        ));
        return;
      case CanStartScan.failed:
        _setResult(const CheckupResult(
          key: 'wifi',
          title: 'Wi-Fi',
          status: CheckupStatus.fail,
          detail: 'Could not start a Wi-Fi scan.',
        ));
        return;
    }

    setState(() {
      _scanning = true;
      _statusText = 'Scanning for nearby networks…';
    });

    try {
      // Android throttles Wi-Fi scans to four per two minutes for a
      // foreground app. Running the checkup a few times in a row hits that
      // ceiling, and startScan then returns false — which used to be reported
      // as "the radio did not start a scan", i.e. a hardware failure, on a
      // radio that was working perfectly.
      //
      // A throttled request is not a broken radio. The platform still holds
      // the results of the last scan, and networks in that list prove the
      // radio can see them, so a refusal falls through to reading those
      // rather than failing.
      final scanning = await WiFiScan.instance.startScan();

      List<WiFiAccessPoint> found = const [];
      // A fresh scan needs time to come back; cached results are there
      // immediately, so a throttled run settles on the first pass.
      final attempts = scanning ? 12 : 2;
      for (var i = 0; i < attempts; i++) {
        try {
          found = await WiFiScan.instance.getScannedResults();
        } catch (_) {
          // Asked too early, or results not readable yet. Keep waiting.
        }
        if (found.isNotEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }

      if (!scanning && found.isEmpty) {
        if (!mounted) return;
        _setResult(const CheckupResult(
          key: 'wifi',
          title: 'Wi-Fi',
          status: CheckupStatus.skipped,
          detail: 'Android would not start another scan yet and had no '
              'recent results. Wait a minute and try again.',
        ));
        return;
      }

      setState(() {
        _networks
          ..clear()
          ..addAll(found);
        _scanning = false;
      });
    } on PlatformException catch (e) {
      if (!mounted) return;
      final message = e.message?.toLowerCase() ?? e.code.toLowerCase();
      if (message.contains('location') || message.contains('accesspoint')) {
        _setResult(const CheckupResult(
          key: 'wifi',
          title: 'Wi-Fi',
          status: CheckupStatus.skipped,
          detail: 'Location services off — required for a Wi-Fi scan.',
        ));
        return;
      }
      if (message.contains('permission') || message.contains('security')) {
        _setResult(const CheckupResult(
          key: 'wifi',
          title: 'Wi-Fi',
          status: CheckupStatus.skipped,
          detail: 'Permission for Wi-Fi scanning was not granted.',
        ));
        return;
      }
      _setResult(CheckupResult(
        key: 'wifi',
        title: 'Wi-Fi',
        status: CheckupStatus.fail,
        detail: 'Wi-Fi scan failed: ${e.message ?? e.code}',
      ));
      return;
    } catch (e) {
      if (!mounted) return;
      _setResult(CheckupResult(
        key: 'wifi',
        title: 'Wi-Fi',
        status: CheckupStatus.fail,
        detail: 'Wi-Fi scan failed: $e',
      ));
      return;
    }

    if (!mounted) return;
    if (_networks.isNotEmpty) {
      final strongest = _networks.where((n) => n.ssid.isNotEmpty).toList()
        ..sort((a, b) => b.level.compareTo(a.level));
      final name = strongest.isNotEmpty ? strongest.first.ssid : null;
      _setResult(CheckupResult(
        key: 'wifi',
        title: 'Wi-Fi',
        status: CheckupStatus.pass,
        detail: 'Found ${_networks.length} network(s)'
            '${name != null ? ', closest: $name' : ''}',
      ));
    } else {
      _setResult(const CheckupResult(
        key: 'wifi',
        title: 'Wi-Fi',
        status: CheckupStatus.fail,
        detail: 'Scan completed but no networks were found.',
      ));
    }
  }

  /// Records the verdict and pops back to the orchestrator.
  ///
  /// [hold] keeps the page open instead: for a verdict the user can act on,
  /// such as a permanently denied permission, popping after a second and a
  /// half would take the only remaining control away with it.
  void _setResult(CheckupResult result, {bool hold = false}) {
    if (!mounted) return;
    setState(() => _result = result);
    if (hold) return;
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) {
        Navigator.of(context).pop(_result);
      }
    });
  }

  void _skipTest() {
    Navigator.of(context).pop(
      const CheckupResult(
        key: 'wifi',
        title: 'Wi-Fi',
        status: CheckupStatus.skipped,
        detail: 'Skipped by user',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CheckupTestShell(
      title: 'Wi-Fi',
      child: _result != null ? _verdictView() : _testView(),
    );
  }

  Widget _testView() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        CheckupInstruction(
          demo: CheckupDemoKind.wifiScan,
          icon: Icons.wifi,
          busy: _scanning,
          text: _statusText,
        ),
        if (_networks.isNotEmpty) ...[
          const SizedBox(height: 16),
          for (final network in _networks.take(6))
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              dense: true,
              leading: const Icon(Icons.wifi, color: AppColors.textSecondary),
              title: Text(
                network.ssid.isEmpty ? '(hidden network)' : network.ssid,
                style: AppTextStyles.bodyMedium,
              ),
              trailing: Text(
                '${network.level} dBm',
                style: AppTextStyles.body
                    .copyWith(color: AppColors.textTertiary, fontSize: 12),
              ),
            ),
        ],
        const SizedBox(height: 16),
        CheckupSkipButton(onSkip: _skipTest),
      ],
    );
  }

  Widget _verdictView() {
    return CheckupVerdict(
      result: _result!,
      // Two verdicts leave the user something to do; every other one is
      // read-only and pops on its own.
      action: _isPermanentlyDenied
          ? CheckupPermissionAction(
              onOpenSettings: openAppSettings,
              onContinue: () => Navigator.of(context).pop(_result),
            )
          : _locationServicesOff
              ? CheckupPermissionAction(
                  onOpenSettings: _retryWithLocation,
                  onContinue: () => Navigator.of(context).pop(_result),
                  openLabel: 'Turn on location & retry',
                  openIcon: Icons.my_location_rounded,
                )
              : null,
    );
  }

  /// Clears the verdict and runs the test again, which raises Android's
  /// location dialog a second time.
  void _retryWithLocation() {
    setState(() {
      _locationServicesOff = false;
      _result = null;
      _networks.clear();
      _statusText = 'Preparing Wi-Fi scan…';
    });
    _run();
  }
}
