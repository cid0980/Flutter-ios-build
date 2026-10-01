import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/checkup_result.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/theme/app_text_styles.dart';
import '../../shared/theme/app_theme.dart';
import 'checkup_test_shell.dart';

/// Display check: a full-screen colour sweep for dead pixels, then a swipe
/// canvas for unresponsive touch areas.
///
/// This is the one screen that deliberately keeps raw colour literals rather
/// than palette tokens. [_DisplayTestPageState._sweepColors], the white swipe
/// canvas, and every foreground derived from `dark ? ... : ...` are part of
/// the test itself — the user is looking AT these colours to judge the panel.
/// Theming them would break what the screen measures. All surrounding chrome
/// uses AppColors/AppTextStyles as normal.

enum _DisplayPhase { sweep, swipe }

/// Test 2 — Display.
///
/// First a full-screen colour sweep (red/green/blue/black/white) to look for
/// dead/stuck pixels, then a full-screen swipe test that tracks how much of the
/// display has been physically swiped and auto-passes once ~90% is covered.
class DisplayTestPage extends StatefulWidget {
  const DisplayTestPage({super.key});

  @override
  State<DisplayTestPage> createState() => _DisplayTestPageState();
}

class _DisplayTestPageState extends State<DisplayTestPage> {
  static const _sweepColors = [
    Color(0xFFE53935),
    Color(0xFF43A047),
    Color(0xFF1E88E5),
    Color(0xFF000000),
    Color(0xFFFFFFFF),
  ];

  static const _targetCoverage = 0.9;
  static const _cellCols = 16;

  _DisplayPhase _phase = _DisplayPhase.sweep;
  int _sweepIndex = 0;

  Offset? _lastDrag;
  final Set<int> _coveredCells = {};
  int _totalCells = 0;
  bool _passedSwipe = false;
  CheckupResult? _result;

  @override
  void initState() {
    super.initState();
    // Do not use immersiveSticky to avoid status bar black line artifact
    _updateStatusBarOverlay();
    // Said once, up front, so that nothing has to be written over the
    // colours afterwards. Without it the first screen is a bare red
    // rectangle with no hint that tapping does anything — and the only other
    // way out is the back button, which abandons the whole checkup.
    WidgetsBinding.instance.addPostFrameCallback((_) => _explain());
  }

  Future<void> _explain() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: AppRadius.card),
        title: Text('Checking the screen', style: AppTextStyles.h3),
        content: Text(
          'Five colours will fill the screen, one at a time. On each one, '
          'look for dots that stay black or stay coloured, patches of a '
          'different shade, or lines across the panel.\n\n'
          'Tap the screen when you have looked.',
          style: AppTextStyles.body.copyWith(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              _skipTest();
            },
            child: Text(
              'Skip this test',
              style:
                  AppTextStyles.button.copyWith(color: AppColors.textTertiary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(
              'Start',
              style: AppTextStyles.button.copyWith(color: AppColors.primary),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    // Put back exactly what main() set, not SystemUiOverlayStyle.light.
    //
    // `light` means light *icons*, for a dark bar — correct while a black
    // sweep frame is on screen, wrong everywhere else. Leaving it behind
    // turned the status bar white-on-white for the rest of the session, so
    // the clock and battery vanished on every screen after this test until
    // the app was restarted.
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light,
    ));
    super.dispose();
  }

  void _updateStatusBarOverlay() {
    if (_phase == _DisplayPhase.sweep) {
      final color = _sweepColors[_sweepIndex];
      final dark = color.computeLuminance() < 0.5;
      SystemChrome.setSystemUIOverlayStyle(
        SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
          statusBarBrightness: dark ? Brightness.dark : Brightness.light,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarDividerColor: Colors.transparent,
          systemNavigationBarIconBrightness:
              dark ? Brightness.light : Brightness.dark,
        ),
      );
    } else {
      SystemChrome.setSystemUIOverlayStyle(
        const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.dark,
          statusBarBrightness: Brightness.light,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarDividerColor: Colors.transparent,
          systemNavigationBarIconBrightness: Brightness.dark,
        ),
      );
    }
  }

  void _setResult(CheckupResult result) {
    if (!mounted) return;
    setState(() => _result = result);
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) {
        Navigator.of(context).pop(_result);
      }
    });
  }

  void _markPass(String detail) {
    _setResult(CheckupResult(
      key: 'display',
      title: 'Display',
      status: CheckupStatus.pass,
      detail: detail,
    ));
  }

  void _markFailed(String detail) {
    _setResult(CheckupResult(
      key: 'display',
      title: 'Display',
      status: CheckupStatus.fail,
      detail: detail,
    ));
  }

  void _skipTest() {
    Navigator.of(context).pop(
      const CheckupResult(
        key: 'display',
        title: 'Display',
        status: CheckupStatus.skipped,
        detail: 'Skipped by user',
      ),
    );
  }

  void _sweepLooksGood() {
    if (_sweepIndex < _sweepColors.length - 1) {
      setState(() {
        _sweepIndex++;
        _updateStatusBarOverlay();
      });
    } else {
      setState(() {
        _phase = _DisplayPhase.swipe;
        _updateStatusBarOverlay();
      });
    }
  }

  void _onDragStart(Offset position) {
    setState(() {
      _lastDrag = position;
      _markCellsFor(position);
    });
  }

  void _onDragUpdate(Offset position) {
    final from = _lastDrag;
    if (from == null) {
      setState(() {
        _lastDrag = position;
        _markCellsFor(position);
      });
      return;
    }
    setState(() {
      _markCellsForLine(from, position);
      _lastDrag = position;
    });

    final coverage =
        _totalCells == 0 ? 0.0 : _coveredCells.length / _totalCells;
    if (coverage >= _targetCoverage && !_passedSwipe) {
      _passedSwipe = true;
      _markPass(
        'Swiped across ${(coverage * 100).toStringAsFixed(0)}% of the display and all 5 colours looked good',
      );
    }
  }

  void _markCellsFor(Offset position) {
    if (_totalCells == 0) return;
    final cellW = _cellWidth;
    final col = (position.dx / cellW).floor().clamp(0, _cellCols - 1);
    final row = (position.dy / _cellHeight).floor().clamp(0, _cellRows - 1);
    _coveredCells.add(row * _cellCols + col);
  }

  void _markCellsForLine(Offset from, Offset to) {
    final distance = (to - from).distance;
    if (distance <= 0) return;
    const sampleEvery = 4.0;
    final steps = (distance / sampleEvery).ceil();
    for (var i = 0; i <= steps; i++) {
      final t = i / steps;
      _markCellsFor(Offset.lerp(from, to, t) ?? to);
    }
  }

  double get _cellWidth =>
      _totalCells == 0 ? 1 : (_canvasSize.width / _cellCols);
  double get _cellHeight =>
      _totalCells == 0 ? 1 : (_canvasSize.height / _cellRows);
  int get _cellRows => _totalCells == 0 ? 1 : (_totalCells / _cellCols).round();

  Size get _canvasSize => _lastCanvasSize;

  Size _lastCanvasSize = const Size(360, 640);

  @override
  Widget build(BuildContext context) {
    if (_result != null) {
      return _verdictView();
    }
    return _phase == _DisplayPhase.sweep ? _sweepView() : _swipeView();
  }

  Widget _sweepView() {
    final color = _sweepColors[_sweepIndex];

    // Nothing on top of the colour. Not a progress row, not a caption, not a
    // button — this screen is the instrument, and anything drawn over it hides
    // the very pixels the test is looking for. A dead pixel under a label is
    // a dead pixel nobody finds.
    //
    // Which leaves nothing on screen to explain itself, so the instruction is
    // given before the colours start and the only gesture is a tap anywhere,
    // which opens the question rather than answering it.
    return Scaffold(
      backgroundColor: color,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _askAboutThisColour,
        child: const SizedBox.expand(),
      ),
    );
  }

  /// Asked on a tap, over the colour rather than instead of it.
  ///
  /// Both answers are deliberately plain statements about what the screen
  /// looks like. "Next" alone would let someone tap through five colours
  /// without ever having been asked anything.
  Future<void> _askAboutThisColour() async {
    if (!mounted) return;

    final last = _sweepIndex == _sweepColors.length - 1;
    final answer = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: AppRadius.card),
        title: Text('How does the screen look?', style: AppTextStyles.h3),
        content: Text(
          'Look for dots that stay black or stay coloured, patches that are '
          'a different shade, or lines across the screen.',
          style: AppTextStyles.body.copyWith(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop('skip'),
            child: Text(
              'Skip',
              style:
                  AppTextStyles.button.copyWith(color: AppColors.textTertiary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop('fail'),
            child: Text(
              'Issue found',
              style: AppTextStyles.button.copyWith(color: AppColors.error),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop('next'),
            child: Text(
              last ? 'Looks fine, finish' : 'Looks fine, next colour',
              style: AppTextStyles.button.copyWith(color: AppColors.primary),
            ),
          ),
        ],
      ),
    );

    // Dismissed without choosing — the colour stays up, which is the right
    // outcome for someone who tapped by accident.
    if (!mounted || answer == null) return;

    switch (answer) {
      case 'fail':
        _markFailed(
          'User reported a display fault on the '
          '${_colourName(_sweepIndex)} screen',
        );
      case 'skip':
        _skipTest();
      default:
        _sweepLooksGood();
    }
  }

  static String _colourName(int index) => switch (index) {
        0 => 'red',
        1 => 'green',
        2 => 'blue',
        3 => 'black',
        _ => 'white',
      };

  Widget _swipeView() {
    return Scaffold(
      backgroundColor: Colors.white,
      extendBody: true,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          _lastCanvasSize = size;
          if (_totalCells == 0) {
            _totalCells =
                _cellCols * (size.height / (size.width / _cellCols)).ceil();
            _coveredCells.clear();
          }
          final coverage = _coveredCells.length / _totalCells;

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (details) => _onDragStart(details.localPosition),
            onPanUpdate: (details) => _onDragUpdate(details.localPosition),
            onPanEnd: (_) => _lastDrag = null,
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _CoveragePainter(
                      covered: _coveredCells,
                      cols: _cellCols,
                      rows: _cellRows,
                      size: size,
                    ),
                  ),
                ),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: _swipeHeader(coverage),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _swipeFooter(coverage),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _swipeHeader(double coverage) {
    final pct = (coverage * 100).toStringAsFixed(0);
    return Container(
      padding: EdgeInsets.fromLTRB(
          16, 10 + MediaQuery.paddingOf(context).top, 16, 6),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(AppRadius.full),
            ),
            child: Text(
              'Swipe to reveal — $pct%',
              style: AppTextStyles.body.copyWith(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          const Spacer(),
          Container(
            width: 90,
            height: 6,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(3),
            ),
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: coverage.clamp(0.0, 1.0),
              child: Container(
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _swipeFooter(double coverage) {
    final pct = ((1 - coverage.clamp(0.0, 1.0)) * 100).toStringAsFixed(0);
    return Container(
      padding: EdgeInsets.fromLTRB(
          16, 6, 16, 16 + MediaQuery.paddingOf(context).bottom),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.error,
                side: const BorderSide(color: AppColors.error),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: () => _markFailed('A display issue was reported'),
              child: Text('Issue found',
                  style:
                      AppTextStyles.body.copyWith(fontWeight: FontWeight.w700)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                'Swipe over the whole screen — $pct% left. Reaches ~90% to pass.',
                textAlign: TextAlign.center,
                style: AppTextStyles.body.copyWith(
                    fontSize: 11.5, height: 1.3, color: AppColors.textPrimary),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Only the verdict adopts the shared chrome. The sweep and swipe views
  /// deliberately do not: their colours are the test, not decoration.
  Widget _verdictView() => CheckupTestShell(
        title: 'Display',
        child: CheckupVerdict(result: _result!),
      );
}

class _CoveragePainter extends CustomPainter {
  final Set<int> covered;
  final int cols;
  final int rows;
  final Size size;

  _CoveragePainter({
    required this.covered,
    required this.cols,
    required this.rows,
    required this.size,
  });

  @override
  void paint(Canvas canvas, Size animation) {
    final cellW = size.width / cols;
    final cellH = size.height / rows;

    final background = Paint()..color = AppColors.surfaceMuted;
    canvas.drawRect(Offset.zero & size, background);

    final grid = Paint()
      ..color = AppColors.borderStrong
      ..strokeWidth = 1;
    for (var r = 0; r <= rows; r++) {
      canvas.drawLine(
        Offset(0, r * cellH),
        Offset(size.width, r * cellH),
        grid,
      );
    }
    for (var c = 0; c <= cols; c++) {
      canvas.drawLine(
        Offset(c * cellW, 0),
        Offset(c * cellW, size.height),
        grid,
      );
    }

    final ink = Paint()..color = AppColors.primary;
    for (final index in covered) {
      final row = index ~/ cols;
      final col = index % cols;
      canvas.drawRect(
        Rect.fromLTWH(col * cellW, row * cellH, cellW, cellH),
        ink,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CoveragePainter oldDelegate) {
    return oldDelegate.covered.length != covered.length ||
        oldDelegate.size != size ||
        oldDelegate.cols != cols ||
        oldDelegate.rows != rows;
  }
}
