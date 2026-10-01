import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import '../models/checkup_result.dart';
import '../models/device_question.dart';
import '../models/quote_breakdown.dart';
import '../shared/widgets/quote_breakdown_view.dart';

import '../shared/motion/motion.dart';
import '../shared/theme/app_colors.dart';
import '../shared/theme/app_text_styles.dart';
import '../shared/theme/app_theme.dart';
import '../shared/services/battery_band.dart';
import '../shared/widgets/condition_icon.dart';
import '../shared/widgets/widgets.dart';
import 'biometric_diagnostic_page.dart';
import 'pickup_checkout_page.dart';

class DeviceEvaluationWizard extends StatefulWidget {
  final String brandName;
  final String modelDocId;
  final String modelName;
  final String? imageUrl;
  final int basePrice;
  final String storage;

  /// What the seller said in the questions stage. These carry their own
  /// deductions, which is why the wizard no longer asks about functional
  /// faults itself.
  final List<DeviceAnswer> answers;

  /// What the automatic checkup found, or empty when it was skipped.
  ///
  /// Recorded and passed on to the order; deliberately *not* priced. The
  /// seller's answers decide the quote — see AutoCheckupOfferPage.
  final List<CheckupResult> checkupResults;

  const DeviceEvaluationWizard({
    super.key,
    required this.brandName,
    required this.modelDocId,
    required this.modelName,
    this.imageUrl,
    required this.basePrice,
    required this.storage,
    this.answers = const [],
    this.checkupResults = const [],
  });

  @override
  State<DeviceEvaluationWizard> createState() => _DeviceEvaluationWizardState();
}

class _DeviceEvaluationWizardState extends State<DeviceEvaluationWizard> {
  static const List<String> _stepTitles = [
    'Screen condition',
    'Body & frame',
    'Battery health',
    'Accessories',
    'Lock status & payout',
  ];

  int _currentStep = 0;

  int _selectedScreenIndex = 0;
  int _selectedBodyIndex = 0;
  int _selectedBatteryIndex = 0;
  int _selectedAccessoryIndex = 0;
  int _selectedLockIndex = 0;
  List<Map<String, dynamic>> _screenOptions = [];
  List<Map<String, dynamic>> _bodyOptions = [];
  List<Map<String, dynamic>> _batteryOptions = [];
  List<Map<String, dynamic>> _accessoryOptions = [];
  List<Map<String, dynamic>> _lockOptions = [];

  bool _isLoadingOptions = true;

  FirebaseFirestore get _catalogFirestore =>
      FirebaseFirestore.instanceFor(app: Firebase.app('catalogApp'));

  @override
  void initState() {
    super.initState();
    _loadDeductionRules();
  }

  /// The charge cycle count the battery test read, if the phone reported one.
  ///
  /// Only Android 14 and later report it; on anything older this stays null
  /// and the seller chooses unaided, as before.
  int? get _measuredCycles {
    for (final result in widget.checkupResults) {
      if (result.key != 'battery') continue;
      final cycles = result.data?['cycleCount'];
      if (cycles is num && cycles > 0) return cycles.round();
    }
    return null;
  }

  /// The cell's real capacity ratio, when the kernel exposed one.
  int? get _measuredHealth {
    for (final result in widget.checkupResults) {
      if (result.key != 'battery') continue;
      final health = result.data?['capacityHealth'];
      if (health is num && health > 0) return health.round();
    }
    return null;
  }

  /// Only ever a real capacity reading — never a guess from the cycle count.
  ///
  /// Converting mileage into a percentage is what made this screen underpay:
  /// the textbook curve called a cell 49% that its own handset measured at
  /// 79%, a whole band lower. Two batteries with identical cycle counts can be
  /// in completely different shape, so when nothing measured the cell, the
  /// seller chooses and the app says nothing.
  int? get _batteryEstimate => _measuredHealth;

  void _applyMeasuredBattery() {
    final health = _batteryEstimate;
    if (health == null) return;
    final index = batteryBandFor(
      health,
      [for (final o in _batteryOptions) (o['title'] ?? '').toString()],
    );
    // No match means the estimate fell in a gap between the bands. Left
    // alone rather than rounded into a neighbour — rounding would move money
    // on arithmetic nobody asked for.
    if (index != null) _selectedBatteryIndex = index;
  }

  /// The fraction of the base price a given option costs.
  double _fractionAt(List<Map<String, dynamic>> list, int index) {
    if (index < 0 || index >= list.length) return 0.0;
    final d = list[index]['deduction'];
    if (d is num) return d.toDouble();
    if (d is String) return double.tryParse(d) ?? 0.0;
    return 0.0;
  }

  /// One line for a chosen option, or null when it costs nothing.
  ///
  /// A zero-percent choice — a flawless screen, the box included — is the
  /// absence of a deduction, and listing it as "− ₹ 0" pads the table with
  /// rows that say nothing.
  QuoteLine? _lineFor(
    String category,
    List<Map<String, dynamic>> list,
    int index,
  ) {
    final fraction = _fractionAt(list, index);
    if (fraction <= 0) return null;

    return QuoteLine(
      category: category,
      choice: (list[index]['title'] ?? '').toString(),
      percent:
          (list[index]['percent'] as num?)?.round() ?? (fraction * 100).round(),
      amount: (widget.basePrice * fraction).round(),
    );
  }

  /// The quote, itemised.
  ///
  /// Built from exactly the selections the payout is calculated from, so the
  /// lines shown and the figure paid can never disagree.
  QuoteBreakdown _buildQuote() {
    final lines = <QuoteLine>[];
    void add(QuoteLine? line) {
      if (line != null) lines.add(line);
    }

    add(_lineFor('Screen condition', _screenOptions, _selectedScreenIndex));
    add(_lineFor('Body & frame', _bodyOptions, _selectedBodyIndex));
    add(_lineFor('Battery health', _batteryOptions, _selectedBatteryIndex));
    for (final answer in widget.answers) {
      if (!answer.isFault) continue;
      add(QuoteLine(
        category: 'Functionality fault',
        choice: answer.question.label,
        percent: answer.question.percent,
        amount: (widget.basePrice * answer.question.fraction).round(),
      ));
    }
    add(_lineFor('Accessories', _accessoryOptions, _selectedAccessoryIndex));
    add(_lineFor('Lock status', _lockOptions, _selectedLockIndex));

    var totalFraction = _fractionAt(_screenOptions, _selectedScreenIndex) +
        _fractionAt(_bodyOptions, _selectedBodyIndex) +
        _fractionAt(_batteryOptions, _selectedBatteryIndex) +
        _fractionAt(_accessoryOptions, _selectedAccessoryIndex) +
        _fractionAt(_lockOptions, _selectedLockIndex);
    for (final answer in widget.answers) {
      if (answer.isFault) totalFraction += answer.question.fraction;
    }

    return QuoteBreakdown.from(
      basePrice: widget.basePrice,
      lines: lines,
      totalFraction: totalFraction,
    );
  }

  int _calculateFinalValuation() => _buildQuote().finalPayout;

  void _nextStep() {
    if (_currentStep < 4) {
      setState(() => _currentStep++);
    }
  }

  void _prevStep() {
    if (_currentStep > 0) {
      setState(() => _currentStep--);
    } else {
      Navigator.pop(context);
    }
  }

  Future<void> _loadDeductionRules() async {
    setState(() {
      _isLoadingOptions = true;
    });

    try {
      final ids = [
        'screen_condition',
        'body_condition',
        'battery_health',
        'accessories',
        'lock_status',
      ];

      final col = _catalogFirestore.collection('deduction_rules');
      final results = <List<Map<String, dynamic>>>[];

      for (final id in ids) {
        try {
          final doc = await col.doc(id).get();
          final data = doc.data();
          final rawOptions = (data != null && data['options'] is List)
              ? List.from(data['options'])
              : [];

          final mapped = rawOptions.map<Map<String, dynamic>>((o) {
            final label = (o['label'] ?? '').toString();
            final iconUrl = (o['icon_url'] ?? '').toString().trim();
            double deduction = 0.0;
            // Firestore stores whole-number percent (e.g. 30 meaning 30%).
            if (o['percent'] is num) {
              deduction = (o['percent'] as num).toDouble() / 100.0;
            } else if (o['percent'] is String) {
              deduction = (double.tryParse(o['percent']) ?? 0.0) / 100.0;
            }

            final percent = (deduction * 100).round();

            return {
              'title': label,
              'subtitle': '$percent% Deduction',
              'percent': percent,
              'deduction': deduction,
              'icon_url': iconUrl,
            };
          }).toList();

          results.add(mapped);
        } catch (_) {
          results.add([]);
        }
      }

      setState(() {
        _screenOptions = results.isNotEmpty ? results[0] : [];
        _bodyOptions = results.length > 1 ? results[1] : [];
        _batteryOptions = results.length > 2 ? results[2] : [];
        _accessoryOptions = results.length > 3 ? results[3] : [];
        _lockOptions = results.length > 4 ? results[4] : [];

        // clamp selected indices to available lengths
        _selectedScreenIndex = _selectedScreenIndex.clamp(
            0, _screenOptions.isEmpty ? 0 : _screenOptions.length - 1);
        _selectedBodyIndex = _selectedBodyIndex.clamp(
            0, _bodyOptions.isEmpty ? 0 : _bodyOptions.length - 1);
        _selectedBatteryIndex = _selectedBatteryIndex.clamp(
            0, _batteryOptions.isEmpty ? 0 : _batteryOptions.length - 1);
        // Applied once the options exist, since the band is chosen by
        // matching the labels rather than by a fixed position.
        _applyMeasuredBattery();
        _selectedAccessoryIndex = _selectedAccessoryIndex.clamp(
            0, _accessoryOptions.isEmpty ? 0 : _accessoryOptions.length - 1);
        _selectedLockIndex = _selectedLockIndex.clamp(
            0, _lockOptions.isEmpty ? 0 : _lockOptions.length - 1);

        // remove selected faults outside range
      });
    } catch (e) {
      setState(() {
        _screenOptions = [];
        _bodyOptions = [];
        _batteryOptions = [];
        _accessoryOptions = [];
        _lockOptions = [];
      });
    } finally {
      setState(() {
        _isLoadingOptions = false;
      });
    }
  }

  void _openCheckout() {
    // The quote is built once and carried, rather than recomputed at
    // checkout: two calculations of the same number is two chances for them
    // to differ, and the validity window has to start somewhere definite.
    context.pushScreen(
      PickupCheckoutPage(
        brandName: widget.brandName,
        modelDocId: widget.modelDocId,
        modelName: widget.modelName,
        imageUrl: widget.imageUrl,
        variant: widget.storage,
        basePrice: widget.basePrice,
        finalPayout: _calculateFinalValuation(),
        quote: _buildQuote(),
        checkupResults: widget.checkupResults,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLastStep = _currentStep == 4;

    return Theme(
      data: AppTheme.light,
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.screenGutter,
                  AppSpacing.lg,
                  AppSpacing.screenGutter,
                  AppSpacing.lg,
                ),
                child: AppScreenHeader(
                  title: _stepTitles[_currentStep],
                  onBack: _prevStep,
                  trailing: AppBadge(
                    label: 'STEP ${_currentStep + 1}/5',
                    tone: AppBadgeTone.primary,
                  ),
                  content: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AppStepProgress(total: 5, current: _currentStep),
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        isLastStep
                            ? 'Review your final estimated cash payout'
                            : 'Select the options that apply to your device',
                        style: AppTextStyles.bodySmall,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [widget.modelName, widget.storage]
                            .where((s) => s.isNotEmpty)
                            .join(' · '),
                        style: AppTextStyles.label,
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(child: _buildStepBody()),
            ],
          ),
        ),
        bottomNavigationBar: AppBottomBar(
          child: isLastStep ? _buildPayoutBar() : _buildContinueBar(),
        ),
      ),
    );
  }

  Widget _buildContinueBar() {
    return AppPrimaryButton(
      label: 'Continue',
      icon: Icons.arrow_forward_rounded,
      onPressed: _nextStep,
    );
  }

  Widget _buildPayoutBar() {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Calculated value', style: AppTextStyles.caption),
              // Counts to the new figure so a changed selection is visibly
              // reflected in the payout rather than silently swapped.
              AppAnimatedCount(
                value: _calculateFinalValuation(),
                prefix: '₹ ',
                style: AppTextStyles.h1.copyWith(
                  color: AppColors.onPrimarySoft,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.lg),
        AppPrimaryButton(
          label: 'Get paid',
          expand: false,
          onPressed: _openCheckout,
        ),
      ],
    );
  }

  Widget _buildStepBody() {
    if (_isLoadingOptions) {
      return GridView.builder(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.screenGutter,
          0,
          AppSpacing.screenGutter,
          AppSpacing.xxl,
        ),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          childAspectRatio: 0.95,
          crossAxisSpacing: AppSpacing.md,
          mainAxisSpacing: AppSpacing.md,
        ),
        itemCount: 4,
        itemBuilder: (_, __) => const OptionCardSkeleton(),
      );
    }

    switch (_currentStep) {
      case 0:
        return _buildSingleSelectGrid(
          _screenOptions,
          _selectedScreenIndex,
          (i) => setState(() => _selectedScreenIndex = i),
          category: ConditionCategory.screen,
        );
      case 1:
        return _buildSingleSelectGrid(
          _bodyOptions,
          _selectedBodyIndex,
          (i) => setState(() => _selectedBodyIndex = i),
          category: ConditionCategory.body,
        );
      case 2:
        final measured = _measuredCycles;
        final health = _batteryEstimate;
        final grid = _buildSingleSelectGrid(
          _batteryOptions,
          _selectedBatteryIndex,
          (i) => setState(() => _selectedBatteryIndex = i),
          category: ConditionCategory.battery,
        );
        // A cycle count alone is still worth showing — it is a real fact
        // about the phone — but it no longer picks the band.
        if (health == null && measured == null) return grid;

        // Says so when the choice was made for them. A dropdown that decides
        // a third of the payout must never quietly move on its own — and the
        // seller keeps the last word, so it is a starting point rather than
        // a verdict.
        return Column(
          children: [
            AppSurface(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Row(
                children: [
                  const Icon(Icons.verified_rounded,
                      size: 18, color: AppColors.success),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Text(
                      health != null
                          ? 'This battery holds $health% of its original '
                              'capacity, read from the phone itself'
                              '${measured != null ? ', after $measured charge cycles' : ''}'
                              '. That band is picked below — change it if you '
                              'know better.'
                          : 'This phone reports $measured charge cycles. '
                              'That is mileage, not condition, so the band '
                              'below is left for you to choose.',
                      style: AppTextStyles.caption,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Expanded(child: grid),
          ],
        );
      case 3:
        return _buildSingleSelectGrid(
          _accessoryOptions,
          _selectedAccessoryIndex,
          (i) => setState(() => _selectedAccessoryIndex = i),
          category: ConditionCategory.accessories,
        );
      case 4:
        return _buildFinalStep();
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _emptyOptions() {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.screenGutter),
      child: AppEmptyState(
        title: 'Options unavailable',
        message: 'We could not load the grading options for this step.',
        icon: Icons.rule_outlined,
        onRetry: _loadDeductionRules,
      ),
    );
  }

  /// The last step: the remaining question, then the arithmetic.
  ///
  /// The breakdown belongs here rather than only at checkout — this is where
  /// the seller first sees a number, and a number they cannot check is the
  /// one they stop trusting later.
  Widget _buildFinalStep() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.screenGutter,
        0,
        AppSpacing.screenGutter,
        AppSpacing.xxl,
      ),
      children: [
        _buildSingleSelectGrid(
          _lockOptions,
          _selectedLockIndex,
          (i) => setState(() => _selectedLockIndex = i),
          category: ConditionCategory.lock,
          embedded: true,
        ),
        const SizedBox(height: AppSpacing.lg),
        AppSurface(
          onTap: () => context.pushScreen(const BiometricDiagnosticPage()),
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Row(
            children: [
              const Icon(
                Icons.fingerprint_rounded,
                size: 24,
                color: AppColors.primary,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Biometric sensor diagnostic',
                      style: AppTextStyles.bodyMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Verify Face ID, Touch ID or fingerprint hardware live',
                      style: AppTextStyles.caption,
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: AppColors.textTertiary,
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xxl),
        const AppSectionHeader(
          title: 'How we got to this price',
          subtitle: 'Every deduction, itemised',
        ),
        const SizedBox(height: AppSpacing.md),
        QuoteBreakdownView(breakdown: _buildQuote()),
      ],
    );
  }

  Widget _grid({
    required int itemCount,
    required IndexedWidgetBuilder builder,
    bool embedded = false,
  }) {
    return GridView.builder(
      // Embedded, the grid is one child of a scrolling column rather than the
      // scroller itself, so it must size to its content and not scroll.
      shrinkWrap: embedded,
      physics: embedded ? const NeverScrollableScrollPhysics() : null,
      padding: embedded
          ? EdgeInsets.zero
          : const EdgeInsets.fromLTRB(
              AppSpacing.screenGutter,
              0,
              AppSpacing.screenGutter,
              AppSpacing.xxl,
            ),
      itemCount: itemCount,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 0.95,
        crossAxisSpacing: AppSpacing.md,
        mainAxisSpacing: AppSpacing.md,
      ),
      itemBuilder: (context, index) =>
          AppReveal(index: index, slots: 6, child: builder(context, index)),
    );
  }

  Widget _buildSingleSelectGrid(
    List<Map<String, dynamic>> items,
    int selectedIndex,
    void Function(int) onSelect, {
    required ConditionCategory category,
    bool embedded = false,
  }) {
    if (items.isEmpty) return _emptyOptions();

    return _grid(
      embedded: embedded,
      itemCount: items.length,
      builder: (context, index) {
        final item = items[index];
        return AppOptionCard(
          title: (item['title'] ?? '').toString(),
          subtitle: (item['subtitle'] ??
                  (item['percent'] != null
                      ? '${item['percent']}% Deduction'
                      : ''))
              .toString(),
          iconUrl: (item['icon_url'] ?? '').toString(),
          art: ConditionIcon(
            category: category,
            label: (item['title'] ?? '').toString(),
            selected: selectedIndex == index,
          ),
          selected: selectedIndex == index,
          onTap: () => onSelect(index),
        );
      },
    );
  }
}

/// The shape of an [AppOptionCard] before the deduction rules arrive.
///
/// Matches the real card — bordered, centred icon, title, subtitle — so the
/// grid does not rearrange itself the moment the rules land.
///
/// Public so its fit inside a grid cell can be tested.
@visibleForTesting
class OptionCardSkeleton extends StatelessWidget {
  const OptionCardSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.card,
        border: Border.all(color: AppColors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Expanded(
              child: Center(
                child: AppShimmer(width: 40, height: 40),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            AppShimmer(
              width: double.infinity,
              height: 12,
              borderRadius: AppRadius.pill,
            ),
            const SizedBox(height: 6),
            AppShimmer(
              width: 56,
              height: 10,
              borderRadius: AppRadius.pill,
            ),
          ],
        ),
      ),
    );
  }
}
