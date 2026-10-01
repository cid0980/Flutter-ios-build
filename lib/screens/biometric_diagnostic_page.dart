import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../shared/theme/app_colors.dart';
import '../shared/theme/app_text_styles.dart';
import '../shared/theme/app_theme.dart';
import '../shared/widgets/widgets.dart';

/// Biometric Hardware Diagnostic integrated from `Reverse-engineering-data-s`.
///
/// Communicates with `fingerprint_test/methods` and `fingerprint_test/events`
/// on both Android (`FingerprintManager`) and iOS (`LocalAuthentication`
/// Face ID / Touch ID) so sellers can verify biometric sensor health and view
/// live hardware callback logs.
class BiometricDiagnosticPage extends StatefulWidget {
  const BiometricDiagnosticPage({super.key});

  @override
  State<BiometricDiagnosticPage> createState() =>
      _BiometricDiagnosticPageState();
}

class _BiometricDiagnosticPageState extends State<BiometricDiagnosticPage> {
  static const MethodChannel _methods =
      MethodChannel('fingerprint_test/methods');
  static const EventChannel _events = EventChannel('fingerprint_test/events');

  StreamSubscription<dynamic>? _sub;

  Map<String, dynamic> _status = const {};
  String _headline = 'Idle';
  Color _headlineColor = AppColors.textSecondary;
  final List<_LogItem> _logs = <_LogItem>[];

  bool get _isIOS => defaultTargetPlatform == TargetPlatform.iOS;

  String get _biometryLabel {
    final type = _status['biometryType']?.toString();
    if (type != null && type.isNotEmpty) return type;
    return _isIOS ? 'Face ID / Touch ID' : 'Fingerprint';
  }

  @override
  void initState() {
    super.initState();
    _sub = _events.receiveBroadcastStream().listen(
      _onEvent,
      onError: (Object err) {
        _addLog('stream_error', err.toString());
      },
    );
    _refreshStatus();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _methods.invokeMethod<dynamic>('cancelAuth').catchError((_) => null);
    super.dispose();
  }

  Future<void> _refreshStatus() async {
    try {
      final res = await _methods.invokeMapMethod<String, dynamic>('getStatus');
      if (!mounted) return;
      setState(() {
        _status = res ?? const {};
      });
      _addLog('status', _formatStatus(_status));
    } catch (e) {
      _addLog('exception', 'getStatus failed: $e');
    }
  }

  Future<void> _startAuth() async {
    try {
      final res = await _methods.invokeMapMethod<String, dynamic>('startAuth');
      if (!mounted) return;
      setState(() {
        _status = res ?? _status;
      });
    } catch (e) {
      _addLog('exception', 'startAuth failed: $e');
    }
  }

  Future<void> _cancelAuth() async {
    try {
      final res = await _methods.invokeMapMethod<String, dynamic>('cancelAuth');
      if (!mounted) return;
      setState(() {
        _status = res ?? _status;
      });
    } catch (e) {
      _addLog('exception', 'cancelAuth failed: $e');
    }
  }

  void _onEvent(dynamic raw) {
    if (!mounted) return;
    final map = (raw is Map)
        ? raw.map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{'type': 'unknown', 'message': raw.toString()};

    final type = (map['type'] ?? 'unknown').toString();
    final code = map['code'];
    final msg = (map['message'] ?? '').toString();

    String line = msg;
    if (code != null) {
      line = '($code) $line';
    }

    setState(() {
      switch (type) {
        case 'listening_started':
          _headline = 'Listening — verify $_biometryLabel now';
          _headlineColor = AppColors.primary;
          break;
        case 'auth_help':
          _headline = 'Help: $line';
          _headlineColor = AppColors.warning;
          break;
        case 'auth_succeeded':
          _headline = 'PASS: $_biometryLabel verified!';
          _headlineColor = AppColors.success;
          break;
        case 'auth_failed':
          _headline = 'Not recognized (try again)';
          _headlineColor = AppColors.warning;
          break;
        case 'auth_error':
        case 'precheck_failed':
        case 'security_exception':
        case 'exception':
        case 'unsupported':
          _headline = 'Error: $line';
          _headlineColor = AppColors.error;
          break;
        case 'listening_stopped':
          _headline = 'Stopped';
          _headlineColor = AppColors.textSecondary;
          break;
        default:
          _headline = '$type: $line';
          _headlineColor = AppColors.textSecondary;
      }
    });

    _addLog(type, line);
    _refreshStatusQuiet();
  }

  Future<void> _refreshStatusQuiet() async {
    try {
      final res = await _methods.invokeMapMethod<String, dynamic>('getStatus');
      if (!mounted) return;
      setState(() {
        _status = res ?? _status;
      });
    } catch (_) {}
  }

  void _addLog(String type, String text) {
    final now = DateTime.now();
    if (!mounted) return;
    setState(() {
      _logs.insert(
        0,
        _LogItem(
          time:
              '${_two(now.hour)}:${_two(now.minute)}:${_two(now.second)}.${(now.millisecond ~/ 100)}',
          type: type,
          text: text,
        ),
      );
      if (_logs.length > 200) {
        _logs.removeRange(200, _logs.length);
      }
    });
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _formatStatus(Map<String, dynamic> s) {
    if (s.isEmpty) return '(empty)';
    return 'sdk=${s['sdkInt']} type=${s['biometryType'] ?? 'n/a'} '
        'supported=${s['supported']} perm=${s['permissionGranted']} '
        'hw=${s['hasHardware']} enrolled=${s['hasEnrolled']} '
        'ready=${s['ready']} listening=${s['listening']}';
  }

  Widget _statusRow(String label, dynamic value) {
    final bool? b = value is bool ? value : null;
    final Color c = b == null
        ? AppColors.textPrimary
        : (b ? AppColors.success : AppColors.error);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: AppTextStyles.bodySmall),
          ),
          Text(
            value?.toString() ?? '-',
            style: AppTextStyles.label.copyWith(color: c),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final listening = _status['listening'] == true;
    final ready = _status['ready'] == true;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.screenGutter,
            AppSpacing.lg,
            AppSpacing.screenGutter,
            AppSpacing.lg,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppScreenHeader(
                title: '$_biometryLabel Diagnostic',
                trailing: IconButton(
                  onPressed: _refreshStatus,
                  tooltip: 'Refresh status',
                  icon: const Icon(
                    Icons.refresh_rounded,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Container(
                padding: const EdgeInsets.all(AppSpacing.lg),
                decoration: BoxDecoration(
                  color: _headlineColor.withValues(alpha: 0.10),
                  borderRadius: AppRadius.card,
                  border: Border.all(color: _headlineColor),
                ),
                child: Row(
                  children: [
                    Icon(
                      _isIOS ? Icons.face_rounded : Icons.fingerprint_rounded,
                      size: 32,
                      color: _headlineColor,
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Text(
                        _headline,
                        style: AppTextStyles.bodyMedium
                            .copyWith(color: _headlineColor),
                      ),
                    ),
                    if (_headline.startsWith('PASS:'))
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(true),
                        child: Text(
                          'Done',
                          style: AppTextStyles.label
                              .copyWith(color: AppColors.success),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              AppSurface(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Device / Sensor Status', style: AppTextStyles.h3),
                    const SizedBox(height: AppSpacing.sm),
                    _statusRow(
                      _isIOS ? 'iOS Major Version' : 'Android SDK',
                      _status['sdkInt'],
                    ),
                    _statusRow('Biometric Type', _biometryLabel),
                    _statusRow(
                      _isIOS
                          ? 'LocalAuthentication Supported'
                          : 'FingerprintManager Supported',
                      _status['supported'],
                    ),
                    _statusRow(
                        'Permission Granted', _status['permissionGranted']),
                    _statusRow('Hardware Detected', _status['hasHardware']),
                    _statusRow('Biometrics Enrolled', _status['hasEnrolled']),
                    _statusRow('Ready to Test', _status['ready']),
                    _statusRow('Currently Listening', _status['listening']),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  Expanded(
                    child: AppPrimaryButton(
                      label: 'Start Listening',
                      icon: Icons.play_arrow_rounded,
                      onPressed: (!listening && ready) ? _startAuth : null,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: listening ? _cancelAuth : null,
                      icon: const Icon(Icons.stop_rounded),
                      label: const Text('Stop'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 52),
                        foregroundColor: AppColors.textPrimary,
                        side: const BorderSide(color: AppColors.borderStrong),
                        shape: RoundedRectangleBorder(
                          borderRadius: AppRadius.field,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  Text('Live Events (newest first)',
                      style: AppTextStyles.label),
                  const Spacer(),
                  TextButton(
                    onPressed: () => setState(_logs.clear),
                    child: Text(
                      'Clear',
                      style: AppTextStyles.caption
                          .copyWith(color: AppColors.primary),
                    ),
                  ),
                ],
              ),
              Expanded(
                child: AppSurface(
                  padding: EdgeInsets.zero,
                  child: _logs.isEmpty
                      ? Center(
                          child: Text(
                            'No events yet.',
                            style: AppTextStyles.caption,
                          ),
                        )
                      : ListView.separated(
                          itemCount: _logs.length,
                          separatorBuilder: (_, __) => const Divider(
                            height: 1,
                            color: AppColors.border,
                          ),
                          itemBuilder: (context, i) {
                            final item = _logs[i];
                            return Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.md,
                                vertical: AppSpacing.sm,
                              ),
                              child: Text(
                                '[${item.time}] ${item.type}: ${item.text}',
                                style: AppTextStyles.caption.copyWith(
                                  fontFamily: 'monospace',
                                  color: AppColors.textPrimary,
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LogItem {
  final String time;
  final String type;
  final String text;

  const _LogItem({
    required this.time,
    required this.type,
    required this.text,
  });
}
