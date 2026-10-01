import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:sim_data/sim_data.dart';

import '../../shared/theme/app_colors.dart';
import '../../shared/theme/app_text_styles.dart';
import '../../shared/theme/app_theme.dart';
import 'checkup_demo.dart';
import 'checkup_test_shell.dart';

/// How a route answered the probe.
enum RouteOutcome {
  /// Reached the internet.
  ok,

  /// Something answered, but it was not the internet — a portal or a proxy.
  captive,

  /// Nothing answered.
  unreachable,

  /// There is no such route on this device right now.
  absent,
}

/// The result of probing one route.
class RouteReport {
  const RouteReport({required this.outcome, this.detail, this.millis});

  final RouteOutcome outcome;
  final String? detail;
  final int? millis;

  bool get works => outcome == RouteOutcome.ok;
}

/// Internet reachability, mobile data in particular.
///
/// A phone can show full bars and a registered SIM and still have no working
/// data — an unpaid bill, an APN that never provisioned, data switched off
/// for that SIM. The existing mobile-network test could not catch that,
/// because an HTTP request from Dart goes out over whatever route Android
/// picks: on a phone connected to Wi-Fi it proved Wi-Fi worked and said the
/// data route was fine.
///
/// This asks the platform for the *cellular* network specifically and sends
/// the probe over that, so Wi-Fi cannot stand in for it. Wi-Fi is then
/// checked separately, because knowing which one is broken is the useful part.
class InternetTestPage extends StatefulWidget {
  const InternetTestPage({super.key});

  @override
  State<InternetTestPage> createState() => _InternetTestPageState();
}

class _InternetTestPageState extends State<InternetTestPage>
    with CheckupTestFlow<InternetTestPage> {
  static const _channel = MethodChannel('french_mobiles/internet');

  /// Returns 204 and an empty body when the connection is genuinely open.
  /// Anything else means something intercepted it.
  static final Uri _probe =
      Uri.parse('https://connectivitycheck.gstatic.com/generate_204');

  @override
  String get testKey => 'internet';
  @override
  String get testTitle => 'Internet';

  RouteReport? _cellular;
  RouteReport? _wifi;
  bool _running = false;
  int _attempt = 1;
  String _status = 'Checking…';

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    setState(() {
      _running = true;
      _cellular = null;
      _wifi = null;
      _status = 'Looking for a mobile data connection…';
    });

    final cellular = await _probeCellular();
    if (!mounted) return;
    setState(() {
      _cellular = cellular;
      _status = 'Checking Wi-Fi…';
    });

    final wifi = await _probeWifi();
    if (!mounted) return;
    setState(() {
      _wifi = wifi;
      _running = false;
    });

    _conclude();
  }

  /// Asks the platform for the cellular network and probes over it.
  Future<RouteReport> _probeCellular() async {
    // With no SIM there is no cellular network to ask for, and the probe
    // below would sit waiting for one that is never going to arrive — half a
    // minute of "Looking for a mobile data connection…" that reads as a hung
    // app. Settle it here in a fraction of a second and move on to Wi-Fi.
    if (await _noSimPresent()) {
      return const RouteReport(
        outcome: RouteOutcome.absent,
        detail: 'No SIM card in this phone',
      );
    }

    try {
      final raw = await _channel
          .invokeMapMethod<String, dynamic>('probeCellular')
          // Shorter than it was: past about ten seconds the answer is not
          // going to change, and the wait is indistinguishable from a freeze.
          .timeout(const Duration(seconds: 12));

      // No reply at all means nothing implements the channel — iOS, or a
      // build without the native side. That is "cannot be tested here", not
      // "this phone's data is broken".
      if (raw == null) {
        return const RouteReport(
          outcome: RouteOutcome.absent,
          detail: 'Mobile data cannot be tested separately on this platform',
        );
      }

      switch (raw['status']) {
        case 'ok':
          return RouteReport(
            outcome: RouteOutcome.ok,
            millis: (raw['ms'] as num?)?.round(),
          );
        case 'captive':
          return RouteReport(
            outcome: RouteOutcome.captive,
            detail: 'The network replied with ${raw['code']} instead of 204',
          );
        case 'no_cellular':
          return const RouteReport(
            outcome: RouteOutcome.absent,
            detail: 'No mobile data network was offered',
          );
        case 'unreachable':
        default:
          return RouteReport(
            outcome: RouteOutcome.unreachable,
            detail: raw['message'] as String?,
          );
      }
    } on MissingPluginException {
      // Not Android. Nothing here can single out the cellular route.
      return const RouteReport(
        outcome: RouteOutcome.absent,
        detail: 'Mobile data cannot be tested separately on this platform',
      );
    } on TimeoutException {
      // A SIM is in the phone — established above — and the route still never
      // answered. That is a real fault, not an absent route, so it must not be
      // softened into "not available".
      return const RouteReport(
        outcome: RouteOutcome.unreachable,
        detail: 'The mobile network never answered',
      );
    } catch (e) {
      return RouteReport(outcome: RouteOutcome.unreachable, detail: '$e');
    }
  }

  /// True only when the phone definitely has no SIM.
  ///
  /// Anything unreadable — no phone-state permission, a plugin error, iOS —
  /// returns false so the probe still runs. Guessing "no SIM" from a failed
  /// read would quietly turn a broken data connection into "not available".
  Future<bool> _noSimPresent() async {
    try {
      final simData =
          await SimDataPlugin.getSimData().timeout(const Duration(seconds: 4));
      return simData.cards.isEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Wi-Fi goes over the ordinary route, which is Wi-Fi when Wi-Fi is up.
  Future<RouteReport> _probeWifi() async {
    try {
      final types = await Connectivity().checkConnectivity();
      if (!types.contains(ConnectivityResult.wifi)) {
        return const RouteReport(
          outcome: RouteOutcome.absent,
          detail: 'Not connected to Wi-Fi',
        );
      }

      final startedAt = DateTime.now();
      final response =
          await http.get(_probe).timeout(const Duration(seconds: 10));
      final millis = DateTime.now().difference(startedAt).inMilliseconds;

      if (response.statusCode == 204) {
        return RouteReport(outcome: RouteOutcome.ok, millis: millis);
      }

      // On iOS (or under widget tests where Dart HttpClient is stubbed to 400),
      // allow the native Wi-Fi interface probe to verify the Wi-Fi route.
      try {
        final nativeWifi = await _channel
            .invokeMapMethod<String, dynamic>('probeWifi')
            .timeout(const Duration(seconds: 5));
        if (nativeWifi != null && nativeWifi['status'] == 'ok') {
          return RouteReport(
            outcome: RouteOutcome.ok,
            millis: (nativeWifi['ms'] as num?)?.round() ?? millis,
          );
        }
      } catch (_) {}

      return RouteReport(
        outcome: RouteOutcome.captive,
        detail: 'Replied with ${response.statusCode} instead of 204 — this '
            'looks like a sign-in portal',
      );
    } catch (e) {
      return RouteReport(outcome: RouteOutcome.unreachable, detail: '$e');
    }
  }

  /// The verdict.
  ///
  /// Mobile data decides it, because that is what a buyer is paying for and
  /// what the seller may not know is broken. Wi-Fi working is reported but
  /// cannot rescue a dead data connection — treating it as a pass is the bug
  /// this test exists to fix.
  void _conclude() {
    final cellular = _cellular;
    final wifi = _wifi;
    if (cellular == null || wifi == null) return;

    if (cellular.works) {
      final speed = cellular.millis != null ? ' (${cellular.millis}ms)' : '';
      markPass('Mobile data reaches the internet$speed'
          '${wifi.works ? ', Wi-Fi does too' : ''}');
      return;
    }

    switch (cellular.outcome) {
      case RouteOutcome.absent:
        // No SIM, or no data network offered at all. Not a fault in itself —
        // a phone sold without a SIM in it cannot be tested this way.
        markNotAvailable(
          '${cellular.detail ?? 'No mobile data available'}. '
          '${wifi.works ? 'Wi-Fi reaches the internet.' : 'Wi-Fi did not reach the internet either.'}',
        );
      case RouteOutcome.captive:
        markFail('Mobile data did not reach the internet: '
            '${cellular.detail ?? 'intercepted'}');
      case RouteOutcome.unreachable:
        markFail(
          'The SIM is registered but mobile data could not reach the '
          'internet${wifi.works ? ', although Wi-Fi can' : ''}.',
        );
      case RouteOutcome.ok:
        break;
    }
  }

  void _retry() {
    setState(() => _attempt++);
    _run();
  }

  @override
  Widget build(BuildContext context) {
    return CheckupTestShell(
      title: 'Internet',
      child: result != null ? CheckupVerdict(result: result!) : _testView(),
    );
  }

  Widget _testView() {
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        CheckupInstruction(
          demo: CheckupDemoKind.dataExchange,
          icon: Icons.language_rounded,
          busy: _running,
          text: _running
              ? _status
              : 'Checked whether this phone can actually reach the internet '
                  'over mobile data, not just whether it has a signal.',
        ),
        const SizedBox(height: AppSpacing.lg),
        _routeTile(
          icon: Icons.signal_cellular_alt_rounded,
          label: 'Mobile data',
          report: _cellular,
        ),
        const SizedBox(height: AppSpacing.md),
        _routeTile(
          icon: Icons.wifi_rounded,
          label: 'Wi-Fi',
          report: _wifi,
        ),
        const SizedBox(height: AppSpacing.lg),
        CheckupActions(
          attempt: _attempt,
          retryLabel: 'Check again',
          onRetry: _running ? null : _retry,
          onIssue: () => markFail('User reported an internet problem'),
          onSkip: skipTest,
        ),
      ],
    );
  }

  Widget _routeTile({
    required IconData icon,
    required String label,
    required RouteReport? report,
  }) {
    final (tone, status) = _appearance(report);

    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.card,
        boxShadow: AppShadows.card,
      ),
      child: Row(
        children: [
          Icon(icon, color: tone),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label, style: AppTextStyles.bodyMedium),
                const SizedBox(height: 2),
                Text(status, style: AppTextStyles.caption),
              ],
            ),
          ),
          if (report != null)
            Icon(
              report.works
                  ? Icons.check_circle_rounded
                  : report.outcome == RouteOutcome.absent
                      ? Icons.remove_circle_outline_rounded
                      : Icons.cancel_rounded,
              size: 20,
              color: tone,
            ),
        ],
      ),
    );
  }

  (Color, String) _appearance(RouteReport? report) {
    if (report == null) return (AppColors.textTertiary, 'Checking…');

    switch (report.outcome) {
      case RouteOutcome.ok:
        final speed = report.millis != null ? ' · ${report.millis}ms' : '';
        return (AppColors.success, 'Reaches the internet$speed');
      case RouteOutcome.captive:
        return (AppColors.warning, report.detail ?? 'Intercepted');
      case RouteOutcome.unreachable:
        return (AppColors.error, 'Could not reach the internet');
      case RouteOutcome.absent:
        return (AppColors.textTertiary, report.detail ?? 'Not available');
    }
  }
}
