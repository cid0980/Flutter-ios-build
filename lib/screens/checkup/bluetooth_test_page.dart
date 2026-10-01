import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../models/checkup_result.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/theme/app_text_styles.dart';
import 'checkup_demo.dart';
import 'checkup_test_shell.dart';

/// Test 5 — Bluetooth.
///
/// Ensures the Bluetooth radio is on and performs a short scan. Passes when
/// scan completes without error. Auto-advances verdict.
/// What to do about the adapter's reported state.
@visibleForTesting
enum AdapterAction {
  /// Already on — scan.
  proceed,

  /// Coming up by itself; wait rather than asking again.
  waitForOn,

  /// Off, and the user has to allow it.
  requestTurnOn,

  /// No radio on this device at all.
  unavailable,

  /// The app is not allowed to use it.
  unauthorized,
}

/// Maps an adapter state onto what the test should do next.
///
/// Pulled out of the flow because getting this wrong is the bug it was
/// written for: `turningOn` and `unknown` are both "not on", and treating
/// them as "off" made the test ask the OS to enable a radio that was already
/// enabling — then report the user as having declined when that went wrong.
@visibleForTesting
AdapterAction actionForAdapterState(BluetoothAdapterState state) {
  switch (state) {
    case BluetoothAdapterState.on:
      return AdapterAction.proceed;
    case BluetoothAdapterState.turningOn:
    case BluetoothAdapterState.unknown:
      return AdapterAction.waitForOn;
    case BluetoothAdapterState.off:
    case BluetoothAdapterState.turningOff:
      return AdapterAction.requestTurnOn;
    case BluetoothAdapterState.unavailable:
      return AdapterAction.unavailable;
    case BluetoothAdapterState.unauthorized:
      return AdapterAction.unauthorized;
  }
}

class BluetoothTestPage extends StatefulWidget {
  const BluetoothTestPage({super.key});

  @override
  State<BluetoothTestPage> createState() => _BluetoothTestPageState();
}

class _BluetoothTestPageState extends State<BluetoothTestPage> {
  bool _scanning = false;
  bool _isPermanentlyDenied = false;
  List<ScanResult> _devices = [];
  String _statusText = 'Requesting Bluetooth access…';
  CheckupResult? _result;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      final btPerm = await Permission.bluetooth.request();
      if (!mounted) return;
      if (btPerm.isPermanentlyDenied) {
        setState(() => _isPermanentlyDenied = true);
        _setResult(
            const CheckupResult(
              key: 'bluetooth',
              title: 'Bluetooth',
              status: CheckupStatus.skipped,
              detail:
                  'Bluetooth permission is permanently denied. Open Settings to grant.',
            ),
            hold: true);
        return;
      }
      if (!btPerm.isGranted && btPerm.isDenied) {
        _setResult(const CheckupResult(
          key: 'bluetooth',
          title: 'Bluetooth',
          status: CheckupStatus.skipped,
          detail: 'Bluetooth permission was not granted.',
        ));
        return;
      }
    } else {
      final scanPerm = await Permission.bluetoothScan.request();
      final connectPerm = await Permission.bluetoothConnect.request();
      final locationPerm = await Permission.location.request();

      if (!mounted) return;

      if (scanPerm.isPermanentlyDenied ||
          connectPerm.isPermanentlyDenied ||
          locationPerm.isPermanentlyDenied) {
        setState(() => _isPermanentlyDenied = true);
        _setResult(
            const CheckupResult(
              key: 'bluetooth',
              title: 'Bluetooth',
              status: CheckupStatus.skipped,
              detail:
                  'Bluetooth/Location permission is permanently denied. Open Settings to grant.',
            ),
            hold: true);
        return;
      }

      if (!scanPerm.isGranted &&
          !connectPerm.isGranted &&
          !locationPerm.isGranted) {
        _setResult(const CheckupResult(
          key: 'bluetooth',
          title: 'Bluetooth',
          status: CheckupStatus.skipped,
          detail: 'Bluetooth permission was not granted.',
        ));
        return;
      }
    }

    setState(() {
      _scanning = true;
      _statusText = 'Turning Bluetooth radio on…';
    });

    try {
      // The first value the adapter reports is not always its settled one: it
      // can be `unknown` before the platform has answered, or `turningOn`
      // while the radio comes up. Treating either as "not on" made the test
      // ask the OS to enable a radio that was already enabling, and a prompt
      // that then threw or was auto-dismissed was reported as the user
      // declining — a failure on a perfectly good radio.
      var state = await FlutterBluePlus.adapterState
          .firstWhere((s) => s != BluetoothAdapterState.unknown)
          .timeout(const Duration(seconds: 10),
              onTimeout: () => BluetoothAdapterState.unknown);

      switch (actionForAdapterState(state)) {
        case AdapterAction.unavailable:
          if (!mounted) return;
          _setResult(const CheckupResult(
            key: 'bluetooth',
            title: 'Bluetooth',
            status: CheckupStatus.notAvailable,
            detail: 'This device has no Bluetooth radio.',
          ));
          return;
        case AdapterAction.unauthorized:
          if (!mounted) return;
          _setResult(const CheckupResult(
            key: 'bluetooth',
            title: 'Bluetooth',
            status: CheckupStatus.skipped,
            detail: 'Bluetooth permission was not granted.',
          ));
          return;
        case AdapterAction.waitForOn:
          // Already coming up on its own; waiting is the whole fix.
          setState(() => _statusText = 'Waiting for the Bluetooth radio…');
          state = await FlutterBluePlus.adapterState
              .firstWhere((s) => s == BluetoothAdapterState.on)
              .timeout(const Duration(seconds: 15),
                  onTimeout: () => BluetoothAdapterState.off);
          break;
        case AdapterAction.requestTurnOn:
          try {
            await FlutterBluePlus.turnOn().timeout(const Duration(seconds: 20));
          } catch (_) {
            if (!mounted) return;
            _setResult(const CheckupResult(
              key: 'bluetooth',
              title: 'Bluetooth',
              status: CheckupStatus.skipped,
              detail:
                  'Bluetooth could not be enabled (system prompt declined).',
            ));
            return;
          }
          state = await FlutterBluePlus.adapterState
              .firstWhere((s) => s == BluetoothAdapterState.on)
              .timeout(const Duration(seconds: 15),
                  onTimeout: () => BluetoothAdapterState.off);
          break;
        case AdapterAction.proceed:
          break;
      }

      if (state != BluetoothAdapterState.on) {
        if (!mounted) return;
        _setResult(const CheckupResult(
          key: 'bluetooth',
          title: 'Bluetooth',
          status: CheckupStatus.skipped,
          detail: 'The Bluetooth radio did not come on in time.',
        ));
        return;
      }

      if (!mounted) return;
      setState(() => _statusText = 'Scanning for nearby Bluetooth devices…');

      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
      final found = await FlutterBluePlus.scanResults
          .firstWhere((list) => list.isNotEmpty)
          .timeout(const Duration(seconds: 12),
              onTimeout: () => <ScanResult>[]);
      await FlutterBluePlus.stopScan();

      if (!mounted) return;
      setState(() {
        _devices = found;
        _scanning = false;
      });
      if (found.isNotEmpty) {
        _setResult(CheckupResult(
          key: 'bluetooth',
          title: 'Bluetooth',
          status: CheckupStatus.pass,
          detail: 'Bluetooth radio works — ${found.length} device(s) found',
        ));
      } else {
        _setResult(const CheckupResult(
          key: 'bluetooth',
          title: 'Bluetooth',
          status: CheckupStatus.pass,
          detail: 'Bluetooth radio works — scan completed (no devices nearby)',
        ));
      }
    } catch (e) {
      if (!mounted) return;
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
      _setResult(CheckupResult(
        key: 'bluetooth',
        title: 'Bluetooth',
        status: CheckupStatus.fail,
        detail: 'Bluetooth test failed: $e',
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
        key: 'bluetooth',
        title: 'Bluetooth',
        status: CheckupStatus.skipped,
        detail: 'Skipped by user',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CheckupTestShell(
      title: 'Bluetooth',
      child: _result != null ? _verdictView() : _testView(),
    );
  }

  Widget _testView() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        CheckupInstruction(
          demo: CheckupDemoKind.bluetoothScan,
          icon: Icons.bluetooth,
          busy: _scanning,
          text: _statusText,
        ),
        if (_devices.isNotEmpty) ...[
          const SizedBox(height: 16),
          for (final result in _devices.take(8))
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              dense: true,
              leading:
                  const Icon(Icons.bluetooth, color: AppColors.textSecondary),
              title: Text(
                result.device.platformName.isEmpty
                    ? result.device.advName.isEmpty
                        ? result.device.remoteId.str
                        : result.device.advName
                    : result.device.platformName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.bodyMedium,
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
