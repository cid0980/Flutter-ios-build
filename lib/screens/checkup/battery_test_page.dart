import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../shared/theme/app_colors.dart';
import '../../shared/theme/app_text_styles.dart';
import '../../shared/theme/app_theme.dart';
import 'checkup_demo.dart';
import 'checkup_test_shell.dart';

/// What the battery says about itself.
///
/// Battery health is the one condition in the whole sell flow that the seller
/// is asked to guess at — the wizard offers "95-100%", "70-79%", "below 70%"
/// and so on, and that choice takes up to 35% off the quote. Somebody who
/// picks optimistically, or simply has no idea, mis-prices the phone by
/// thousands. This measures it where the phone will say.
///
/// **There is no battery health API on Android.** Not at any level — checked
/// against the API 37 android.jar, BatteryManager simply has no such
/// constant. Every app showing a health percentage is estimating one, usually
/// by reflecting into the hidden PowerProfile class for the design capacity,
/// which has been restricted since Android 9 and is only meaningful at a full
/// charge.
///
/// What the platform does give, from Android 14, is the **charge cycle
/// count** — and cycles are what actually wear a cell out. That is reported
/// as the measurement it is, and the wizard turns it into a starting estimate
/// that the seller can correct.
class BatteryTestPage extends StatefulWidget {
  const BatteryTestPage({super.key});

  @override
  State<BatteryTestPage> createState() => _BatteryTestPageState();
}

class _BatteryTestPageState extends State<BatteryTestPage>
    with CheckupTestFlow<BatteryTestPage> {
  static const _channel = MethodChannel('french_mobiles/battery');

  @override
  String get testKey => 'battery';
  @override
  String get testTitle => 'Battery';

  Map<String, dynamic>? _reading;
  bool _running = true;
  int _attempt = 1;

  @override
  void initState() {
    super.initState();
    _read();
  }

  Future<void> _read() async {
    setState(() => _running = true);

    Map<String, dynamic>? reading;
    try {
      reading = (await _channel
              .invokeMapMethod<String, dynamic>('read')
              .timeout(const Duration(seconds: 6)))
          ?.cast<String, dynamic>();
    } on MissingPluginException {
      // Not Android.
    } catch (_) {
      // Unreadable. Treated the same as a phone that will not say.
    }

    if (!mounted) return;
    setState(() {
      _reading = reading;
      _running = false;
    });
    _conclude(reading);
  }

  void _conclude(Map<String, dynamic>? reading) {
    if (reading == null || reading.isEmpty) {
      markNotAvailable('This phone would not report anything about its '
          'battery. Choose the health band yourself in the next step.');
      return;
    }

    final flag = reading['healthFlag'] as String?;
    final cycles = (reading['cycleCount'] as num?)?.round();
    final temperature = (reading['temperatureCelsius'] as num?)?.toDouble();

    // The kernel's own capacity ratio, when the handset exposes it. This is a
    // measurement of the cell, not a guess from its mileage, and it is what
    // other battery apps show — so it wins over the cycle estimate whenever
    // it is present.
    final measured = (reading['capacityHealth'] as num?)?.round();

    final data = <String, dynamic>{
      if (cycles != null) 'cycleCount': cycles,
      if (measured != null) 'capacityHealth': measured,
      if (temperature != null) 'temperatureCelsius': temperature,
      if (flag != null) 'healthFlag': flag,
    };

    // A cell the system itself calls dead, overheating or over-voltage is a
    // fault whatever the percentage says — and it is the case the seller is
    // least likely to admit to.
    if (flag != null &&
        (flag == 'dead' || flag == 'failure' || flag == 'over_voltage')) {
      markFail(
        'The system reports this battery as ${_flagWords(flag)}. It needs '
        'replacing, which the quote should reflect.',
        data: data,
      );
      return;
    }

    if (measured != null) {
      final mileage =
          cycles != null ? ' after $cycles charge cycles' : '';
      // 80% is the industry's own end-of-life line for a lithium cell.
      if (measured < 80) {
        markFail(
          'This battery holds $measured% of its original capacity$mileage. '
          'Worn enough that a buyer will want it replaced.',
          data: data,
        );
      } else {
        markPass(
          'This battery holds $measured% of its original capacity$mileage.',
          data: data,
        );
      }
      return;
    }

    // A cycle count is a real, measured fact, so it is reported — but it is
    // mileage, not condition. A cell cycled gently 800 times can be in better
    // shape than one fast-charged hot 300 times, so no percentage is invented
    // from it and no payout band is chosen on it.
    if (cycles != null) {
      markNotAvailable(
        'This phone reports $cycles charge cycles, but no battery health '
        'figure — Android has no such reading, and this handset does not '
        'expose one. Cycles are how far it has travelled, not what condition '
        'it is in, so choose the health band yourself in the next step.',
        data: data,
      );
      return;
    }

    // Nothing measured at all.
    final isIOS = defaultTargetPlatform == TargetPlatform.iOS;
    markNotAvailable(
      isIOS
          ? 'iOS does not expose battery health percentage or charge cycles to '
              'apps — check Settings → Battery → Battery Health & Charging. '
              'What it did report: ${_summary(reading)}. Choose the health '
              'band yourself in the next step.'
          : 'This phone does not report battery health or charge cycles. Android '
              'has no battery health reading of its own, and the figure some phones '
              'show in Settings comes from the manufacturer, which apps cannot get '
              'at. What it did report: ${_summary(reading)}. Choose the health band '
              'yourself in the next step.',
      data: data,
    );
  }

  String _summary(Map<String, dynamic> reading) {
    final parts = <String>[];
    final flag = reading['healthFlag'] as String?;
    if (flag != null) parts.add('condition ${_flagWords(flag)}');
    final level = (reading['level'] as num?)?.round();
    if (level != null) parts.add('$level% charged');
    final temperature = (reading['temperatureCelsius'] as num?)?.toDouble();
    if (temperature != null) {
      parts.add('${temperature.toStringAsFixed(1)}°C');
    }
    return parts.isEmpty ? 'nothing usable' : parts.join(', ');
  }

  static String _flagWords(String flag) => switch (flag) {
        'good' => 'good',
        'overheat' => 'overheating',
        'dead' => 'dead',
        'over_voltage' => 'over voltage',
        'cold' => 'too cold to judge',
        'failure' => 'failed',
        _ => flag,
      };

  void _retry() {
    setState(() => _attempt++);
    _read();
  }

  @override
  Widget build(BuildContext context) {
    return CheckupTestShell(
      title: 'Battery',
      child: result != null ? CheckupVerdict(result: result!) : _testView(),
    );
  }

  Widget _testView() {
    final reading = _reading;

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        CheckupInstruction(
          icon: Icons.battery_full_rounded,
          busy: _running,
          demo: CheckupDemoKind.batteryHealth,
          text: _running
              ? 'Asking the battery how it is doing…'
              : 'Nothing to do here — this one reads itself.',
        ),
        const SizedBox(height: AppSpacing.lg),
        if (reading != null) _readings(reading),
        const SizedBox(height: AppSpacing.lg),
        CheckupActions(
          attempt: _attempt,
          retryLabel: 'Read again',
          onRetry: _running ? null : _retry,
          onIssue: () => markFail('User reported a battery problem'),
          onSkip: skipTest,
        ),
      ],
    );
  }

  Widget _readings(Map<String, dynamic> reading) {
    final rows = <(String, String)>[];

    // Health only when the cell was actually measured. Nothing is derived
    // from the cycle count: that guess is what reported 49% for a battery
    // its own handset put at 79%.
    final health = (reading['capacityHealth'] as num?)?.round();
    if (health != null) rows.add(('Battery health', '$health%'));

    final cycles = (reading['cycleCount'] as num?)?.round();
    rows.add(('Charge cycles', cycles == null ? 'Not reported' : '$cycles'));

    final capacityLevel = reading['capacityLevel'] as String?;
    if (capacityLevel != null) rows.add(('Capacity level', capacityLevel));

    // Charge remaining in the cell right now. Not the design capacity —
    // Android will not say what that is — so it is shown as what it is
    // rather than dressed up as a health figure.
    final microAmpHours = (reading['chargeMicroAmpHours'] as num?)?.toDouble();
    if (microAmpHours != null) {
      rows.add(('Charge in cell', '${(microAmpHours / 1000).round()} mAh'));
    }

    final microAmps = (reading['currentMicroAmps'] as num?)?.toDouble();
    if (microAmps != null) {
      final milliAmps = microAmps / 1000;
      rows.add(('Current', '${milliAmps.round()} mA'));

      final voltage = (reading['voltage'] as num?)?.toDouble();
      if (voltage != null) {
        final watts = milliAmps / 1000 * voltage;
        rows.add(('Power', '${watts.toStringAsFixed(2)} W'));
      }
    }

    final source = reading['powerSource'] as String?;
    if (source != null) rows.add(('Power source', source));

    final flag = reading['healthFlag'] as String?;
    if (flag != null) rows.add(('Condition', _flagWords(flag)));

    final level = (reading['level'] as num?)?.round();
    if (level != null) rows.add(('Charge now', '$level%'));

    final temperature = (reading['temperatureCelsius'] as num?)?.toDouble();
    if (temperature != null) {
      rows.add(('Temperature', '${temperature.toStringAsFixed(1)}°C'));
    }

    final voltage = (reading['voltage'] as num?)?.toDouble();
    if (voltage != null) {
      rows.add(('Voltage', '${voltage.toStringAsFixed(2)} V'));
    }

    final technology = reading['technology'] as String?;
    if (technology != null && technology.isNotEmpty) {
      rows.add(('Type', technology));
    }

    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.card,
        boxShadow: AppShadows.card,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: [
                  Expanded(
                    child: Text(label, style: AppTextStyles.caption),
                  ),
                  Text(
                    value,
                    style: AppTextStyles.bodyMedium.copyWith(
                      color: value == 'Not reported'
                          ? AppColors.textTertiary
                          : AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            cycles == null
                ? (defaultTargetPlatform == TargetPlatform.iOS
                    ? 'iOS keeps Maximum Capacity in Settings → Battery → '
                        'Battery Health & Charging, so apps cannot read it '
                        'directly. Check that figure and choose the matching '
                        'band next.'
                    : 'Only Android 14 and later report charge cycles, and Android '
                        'has no battery health reading at any version. So this one '
                        'asks you instead.')
                : 'Android has no battery health reading, so the capacity '
                    'figure is estimated from the cycle count — cells are '
                    'specified to hold about 80% after 500 cycles.',
            style: AppTextStyles.caption,
          ),
        ],
      ),
    );
  }
}
