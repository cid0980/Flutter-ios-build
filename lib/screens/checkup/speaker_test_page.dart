import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../../shared/theme/app_colors.dart';
import '../../shared/theme/app_text_styles.dart';
import '../../shared/theme/app_theme.dart';
import 'checkup_demo.dart';
import 'checkup_test_shell.dart';
import 'checkup_tone.dart';

/// Loudspeaker.
///
/// SELF-REPORT ONLY — flagged honestly. There is no way to sensor-verify a
/// speaker from the same device without recording it back, and a mic loopback
/// would conflate two separate components: a failure could be either one.
/// The user's Yes/No is the verdict.
///
/// The tone is synthesised rather than shipped as an asset, so there is no
/// binary blob in the repo and the frequency stays adjustable.
class SpeakerTestPage extends StatefulWidget {
  const SpeakerTestPage({super.key});

  @override
  State<SpeakerTestPage> createState() => _SpeakerTestPageState();
}

class _SpeakerTestPageState extends State<SpeakerTestPage>
    with CheckupTestFlow<SpeakerTestPage> {
  /// 1 kHz: near the ear's most sensitive range, and high enough that a blown
  /// or muffled driver is obvious.
  static const double _frequency = 1000;
  static const double _seconds = 2;

  @override
  String get testKey => 'speaker';
  @override
  String get testTitle => 'Loudspeaker';

  final AudioPlayer _player = AudioPlayer();
  bool _playing = false;
  bool _played = false;
  int _attempt = 1;
  String? _error;

  @override
  void initState() {
    super.initState();
    _play();
  }

  @override
  void dispose() {
    disposeHardware();
    super.dispose();
  }

  @override
  void disposeHardware() {
    _player.stop().catchError((_) => null);
    _player.dispose();
  }

  Future<void> _play() async {
    setState(() {
      _playing = true;
      _error = null;
    });
    try {
      await _player.setAudioContext(
        AudioContext(
          iOS: AudioContextIOS(
            // playback ignores the hardware Ring/Silent switch and routes to
            // the main loudspeaker, even if the earpiece test ran beforehand.
            category: AVAudioSessionCategory.playback,
          ),
        ),
      );
      await _player.setVolume(1);
      await _player.play(BytesSource(
          CheckupTone.steady(frequency: _frequency, seconds: _seconds)));
      await _player.onPlayerComplete.first;
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) {
        setState(() {
          _playing = false;
          _played = true;
        });
      }
    }
  }

  void _retry() {
    setState(() => _attempt++);
    _play();
  }

  @override
  Widget build(BuildContext context) {
    return CheckupTestShell(
      title: 'Loudspeaker',
      child: result != null ? CheckupVerdict(result: result!) : _testView(),
    );
  }

  Widget _testView() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const CheckupInstruction(
          demo: CheckupDemoKind.speakerSound,
          icon: Icons.speaker_outlined,
          text: 'A test tone is playing through the loudspeaker. Hold the '
              'phone away from your ear and listen for a steady beep.',
        ),
        const SizedBox(height: 16),
        _toneTile(),
        if (_error != null) ...[
          const SizedBox(height: 12),
          CheckupInstruction(
            icon: Icons.error_outline,
            tone: AppColors.error,
            text: 'Could not play the tone: $_error',
          ),
        ],
        const SizedBox(height: 16),
        CheckupActions(
          attempt: _attempt,
          primary: _playing || !_played
              ? null
              : () => markPass('User confirmed hearing the test tone'),
          primaryLabel: 'Yes, I heard it',
          retryLabel: 'Play again',
          onRetry: _playing ? null : _retry,
          onIssue: () => markFail(
            'User did not hear the test tone after $_attempt attempt(s)',
          ),
          onSkip: skipTest,
        ),
      ],
    );
  }

  Widget _toneTile() {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: _playing ? AppColors.primarySoft : AppColors.surface,
        borderRadius: AppRadius.card,
        boxShadow: AppShadows.card,
      ),
      child: Column(
        children: [
          Icon(
            _playing ? Icons.volume_up_rounded : Icons.volume_off_rounded,
            size: 44,
            color: _playing ? AppColors.onPrimarySoft : AppColors.textTertiary,
          ),
          const SizedBox(height: 12),
          Text(
            _playing
                ? 'Playing a ${_frequency ~/ 1} Hz tone…'
                : 'Tone finished — did you hear it?',
            textAlign: TextAlign.center,
            style: AppTextStyles.bodyMedium.copyWith(
              color: _playing ? AppColors.onPrimarySoft : AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}
