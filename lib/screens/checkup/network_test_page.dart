import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:sim_data/sim_data.dart';

import '../../models/checkup_result.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/theme/app_text_styles.dart';
import 'checkup_demo.dart';
import 'checkup_test_shell.dart';

/// Test 7 — Mobile network.
///
/// Reads SIM presence + carrier name via the sim_data plugin, then confirms the
/// device currently has a working route to the internet with a lightweight
/// HTTP probe. Auto-advances verdict.
class NetworkTestPage extends StatefulWidget {
  const NetworkTestPage({super.key});

  @override
  State<NetworkTestPage> createState() => _NetworkTestPageState();
}

class _NetworkTestPageState extends State<NetworkTestPage> {
  static const _internetChannel = MethodChannel('french_mobiles/internet');

  bool _isPermanentlyDenied = false;
  String _statusText = 'Reading SIM state…';
  CheckupResult? _result;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      final phone = await Permission.phone.request();
      if (!mounted) return;
      if (phone.isPermanentlyDenied) {
        setState(() => _isPermanentlyDenied = true);
        _setResult(
            const CheckupResult(
              key: 'network',
              title: 'Mobile network',
              status: CheckupStatus.skipped,
              detail:
                  'Phone state permission is permanently denied. Open Settings to grant.',
            ),
            hold: true);
        return;
      }
      if (!phone.isGranted) {
        _setResult(const CheckupResult(
          key: 'network',
          title: 'Mobile network',
          status: CheckupStatus.skipped,
          detail: 'Phone state permission was not granted.',
        ));
        return;
      }
    }

    String? carrier;
    bool hasSim = false;
    try {
      final simData = await SimDataPlugin.getSimData();
      if (simData.cards.isNotEmpty) {
        hasSim = true;
        final card = simData.cards.first;
        carrier =
            card.carrierName.isEmpty ? card.displayName : card.carrierName;
      }
    } on PlatformException catch (e) {
      if (!mounted) return;
      _setResult(CheckupResult(
        key: 'network',
        title: 'Mobile network',
        status: CheckupStatus.skipped,
        detail:
            'Could not read SIM state (sim_data error: ${e.message ?? e.code})',
      ));
      return;
    } catch (e) {
      if (!mounted) return;
      _setResult(CheckupResult(
        key: 'network',
        title: 'Mobile network',
        status: CheckupStatus.skipped,
        detail: 'Could not read SIM state: $e',
      ));
      return;
    }

    if (!mounted) return;
    if (!hasSim) {
      _setResult(const CheckupResult(
        key: 'network',
        title: 'Mobile network',
        status: CheckupStatus.skipped,
        detail: 'No SIM card detected on this device.',
      ));
      return;
    }

    setState(() => _statusText = 'Checking mobile data route…');

    final connectivity = Connectivity();
    final types = await connectivity.checkConnectivity();
    final hasNetwork =
        types.isNotEmpty && !types.every((t) => t == ConnectivityResult.none);

    final routeWorks = await _probeInternet();
    if (!mounted) return;

    if (!hasNetwork) {
      _setResult(const CheckupResult(
        key: 'network',
        title: 'Mobile network',
        status: CheckupStatus.fail,
        detail: 'No active network connection detected.',
      ));
      return;
    }

    if (routeWorks) {
      final carrierLabel = (carrier == null || carrier.isEmpty)
          ? 'carrier name unavailable'
          : 'carrier: $carrier';
      _setResult(CheckupResult(
        key: 'network',
        title: 'Mobile network',
        status: CheckupStatus.pass,
        detail: 'SIM detected ($carrierLabel), and a network route reaches '
            'the internet. The Internet test checks mobile data specifically.',
      ));
    } else {
      _setResult(const CheckupResult(
        key: 'network',
        title: 'Mobile network',
        status: CheckupStatus.fail,
        detail: 'SIM detected but the data route could not reach the internet.',
      ));
    }
  }

  /// Probes over whatever route Android picks — Wi-Fi when Wi-Fi is up.
  ///
  /// Deliberately not presented as proof that mobile data works: it used to
  /// be, and on a phone connected to Wi-Fi that claim was simply untrue. The
  /// Internet test asks for the cellular network specifically.
  Future<bool> _probeInternet() async {
    try {
      final response = await http
          .get(Uri.parse('https://connectivitycheck.gstatic.com/generate_204'))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode >= 200 && response.statusCode < 400) {
        return true;
      }
    } catch (_) {
      // Fall through to native channel probe when available.
    }
    try {
      final probe = await _internetChannel
          .invokeMapMethod<String, dynamic>('probeCellular')
          .timeout(const Duration(seconds: 5));
      if (probe != null &&
          (probe['status'] == 'ok' || probe['status'] == 'captive')) {
        return true;
      }
    } catch (_) {}
    return false;
  }

  /// Records the verdict and pops back to the orchestrator.
  ///
  /// [hold] keeps the page open instead: for a verdict the user can act on,
  /// such as a permanently denied permission, popping after a second and a
  /// half would take the only remaining control away with it.
  void _setResult(CheckupResult result, {bool hold = false}) {
    if (!mounted) return;
    setState(() {
      _result = result;
    });
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
        key: 'network',
        title: 'Mobile network',
        status: CheckupStatus.skipped,
        detail: 'Skipped by user',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CheckupTestShell(
      title: 'Mobile network',
      child: _result != null ? _verdictView() : _testView(),
    );
  }

  Widget _testView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Filling signal bars say "checking the mobile network" without
            // relying on the status text below being readable.
            const CheckupDemo(kind: CheckupDemoKind.signalBars, height: 116),
            const SizedBox(height: 20),
            Text(
              _statusText,
              textAlign: TextAlign.center,
              style: AppTextStyles.body.copyWith(
                  fontSize: 14, height: 1.45, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 20),
            CheckupSkipButton(onSkip: _skipTest),
          ],
        ),
      ),
    );
  }

  Widget _verdictView() {
    return CheckupVerdict(
      result: _result!,
      // Only a permanently denied permission leaves the user something to do
      // here; every other verdict is read-only and pops on its own.
      action: _isPermanentlyDenied
          ? CheckupPermissionAction(
              onOpenSettings: openAppSettings,
              onContinue: () => Navigator.of(context).pop(_result),
            )
          : null,
    );
  }
}
