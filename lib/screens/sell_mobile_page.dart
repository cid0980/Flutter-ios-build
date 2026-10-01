import 'package:flutter/material.dart';

import '../models/models.dart';
import '../shared/motion/motion.dart';
import '../shared/theme/app_colors.dart';
import '../shared/theme/app_text_styles.dart';
import '../shared/theme/app_theme.dart';
import '../shared/widgets/widgets.dart';
import '../shared/services/model_search.dart';
import 'brand_detail_page.dart';
import 'brand_list_page.dart';
import 'biometric_diagnostic_page.dart';
import 'variant_selection_page.dart';

/// Entry point of the sell flow: pick a brand, or search for a model
/// directly.
///
/// All data is local — [brandData], [moreBrandData] and the model list below.
/// This screen performs no Firebase reads.
///
/// Wrapped in [AppTheme.light] locally because `MaterialApp` still carries the
/// app's original inline theme; this can be dropped once the theme is adopted
/// globally.
class SellMobilePage extends StatefulWidget {
  const SellMobilePage({super.key});

  @override
  State<SellMobilePage> createState() => _SellMobilePageState();
}

class _SellMobilePageState extends State<SellMobilePage> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  List<BrandModel> _filteredBrands = brandData;
  List<ModelDetail> _filteredModels = [];
  bool _isSearching = false;

  /// Real models, read once from the catalogue. Empty until they arrive.
  List<ModelDetail> _allModels = const [];

  final List<BrandModel> otherBrandData = moreBrandData;

  @override
  void initState() {
    super.initState();
    _loadModels();
  }

  Future<void> _loadModels() async {
    try {
      final models = await ModelSearch.load();
      if (!mounted) return;
      setState(() {
        _allModels = models;
        // Re-filter, in case the user typed before the catalogue arrived.
        if (_isSearching) {
          _filteredModels =
              ModelSearch.filter(models, _searchController.text);
        }
      });
    } catch (_) {
      // Brands still work without it; the model results simply stay empty
      // rather than the page failing to open.
    }
  }

  void _onSearchChanged(String query) {
    setState(() {
      if (query.trim().isEmpty) {
        _isSearching = false;
        _filteredBrands = brandData;
        _filteredModels = [];
      } else {
        _isSearching = true;

        _filteredBrands = brandData
            .where((brand) =>
                brand.name.toLowerCase().contains(query.toLowerCase()) ||
                brand.logoText.toLowerCase().contains(query.toLowerCase()))
            .toList();

        _filteredModels = ModelSearch.filter(_allModels, query);
      }
    });
  }

  void _clearSearch() {
    _searchController.clear();
    _onSearchChanged('');
    FocusScope.of(context).unfocus();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  // --- Navigation --------------------------------------------------------

  void _navigateToBrandDetail(BrandModel brand) {
    context.pushScreen(BrandDetailPage(
          brandName: brand.name,
          themeColor: brand.themeColor),
    );
  }

  void _openBrandList() {
    context.pushScreen(const BrandListPage(),
    );
  }

  /// Opens the variant list for a searched model.
  ///
  /// Deliberately not the grading wizard: the wizard needs a base price, and
  /// the only honest source for one is the model's own variants. This used to
  /// jump straight there with a flat ₹50,000 and no brand, so every searched
  /// phone was graded against the same invented figure.
  void _openModel(ModelDetail model) {
    context.pushScreen(VariantSelectionPage(
      brandName: model.brand,
      modelDocId: model.docId ?? '',
      modelName: model.name,
      imageUrl: model.imageUrl,
    ));
  }

  void _showHelpSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
      ),
      builder: (_) => const _HelpSheet(),
    );
  }

  // --- Build -------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: AppTheme.light,
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: SafeArea(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => FocusScope.of(context).unfocus(),
            child: CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.screenGutter,
                    AppSpacing.lg,
                    AppSpacing.screenGutter,
                    0,
                  ),
                  sliver: SliverToBoxAdapter(child: _buildHeader()),
                ),
                SliverPersistentHeader(
                  pinned: true,
                  delegate: AppStickySearchHeader(
                    child: AppSearchField(
                      controller: _searchController,
                      focusNode: _searchFocusNode,
                      hintText: 'Search model (e.g. iPhone 13)',
                      onChanged: _onSearchChanged,
                      trailing: _isSearching
                          ? IconButton(
                              icon: const Icon(
                                Icons.close_rounded,
                                size: 18,
                                color: AppColors.textSecondary,
                              ),
                              onPressed: _clearSearch,
                            )
                          : null,
                    ),
                  ),
                ),
                if (_isSearching && _filteredModels.isNotEmpty)
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.screenGutter,
                      AppSpacing.lg,
                      AppSpacing.screenGutter,
                      0,
                    ),
                    sliver: SliverToBoxAdapter(child: _buildModelResults()),
                  ),
                const SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    AppSpacing.screenGutter,
                    AppSpacing.xxl,
                    AppSpacing.screenGutter,
                    0,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: AppSectionHeader(
                      title: 'Top mobile brands',
                      subtitle: 'Most traded on French Mobiles',
                    ),
                  ),
                ),
                const SliverToBoxAdapter(
                  child: SizedBox(height: AppSpacing.md),
                ),
                SliverToBoxAdapter(child: _buildTopBrandRail()),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.screenGutter,
                    AppSpacing.xxl,
                    AppSpacing.screenGutter,
                    0,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: AppSectionHeader(
                      title: 'More brands',
                      actionLabel: 'View all',
                      onActionTap: _openBrandList,
                    ),
                  ),
                ),
                const SliverToBoxAdapter(
                  child: SizedBox(height: AppSpacing.md),
                ),
                _buildBrandGrid(),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.screenGutter,
                    AppSpacing.xl,
                    AppSpacing.screenGutter,
                    AppSpacing.xxxl,
                  ),
                  sliver: SliverToBoxAdapter(child: _buildMissingBrandHint()),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return AppScreenHeader(
      title: 'Sell Old Phone',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Biometric sensor check',
            icon: const Icon(
              Icons.fingerprint_rounded,
              color: AppColors.primary,
            ),
            onPressed: () {
              context.pushScreen(const BiometricDiagnosticPage());
            },
          ),
          IconButton(
            tooltip: 'Sell help & FAQs',
            icon: const Icon(
              Icons.help_outline_rounded,
              color: AppColors.primary,
            ),
            onPressed: _showHelpSheet,
          ),
        ],
      ),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Get instant cash for your old phone', style: AppTextStyles.h1),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              const Icon(
                Icons.verified_user_outlined,
                size: 16,
                color: AppColors.primary,
              ),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Text(
                  'Free doorstep pickup & instant payment',
                  style: AppTextStyles.bodySmall,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildModelResults() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Text('Matching models', style: AppTextStyles.h3),
            const SizedBox(width: AppSpacing.sm),
            AppBadge(
              label: '${_filteredModels.length}',
              tone: AppBadgeTone.primary,
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: AppRadius.card,
            border: Border.all(color: AppColors.border),
            boxShadow: AppShadows.card,
          ),
          child: Column(
            children: [
              for (var i = 0; i < _filteredModels.length; i++) ...[
                if (i > 0)
                  const Divider(
                    height: 1,
                    thickness: 1,
                    indent: AppSpacing.lg,
                    endIndent: AppSpacing.lg,
                    color: AppColors.border,
                  ),
                _ModelResultTile(
                  model: _filteredModels[i],
                  onTap: () => _openModel(_filteredModels[i]),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTopBrandRail() {
    if (_filteredBrands.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: AppSpacing.screenGutter),
        child: AppEmptyState(
          title: 'No matching brands',
          message: 'Try a different name, or browse the full list below.',
          icon: Icons.search_off_rounded,
        ),
      );
    }

    return SizedBox(
      height: 148,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.screenGutter,
        ),
        itemCount: _filteredBrands.length,
        separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.md),
        itemBuilder: (context, index) {
          final brand = _filteredBrands[index];
          return _Reveal(
            index: index,
            child: AppBrandCard(
              brand: brand,
              width: 132,
              onTap: () => _navigateToBrandDetail(brand),
            ),
          );
        },
      ),
    );
  }

  Widget _buildBrandGrid() {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.screenGutter,
      ),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: AppSpacing.md,
          mainAxisSpacing: AppSpacing.md,
          childAspectRatio: 0.88,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            if (index == otherBrandData.length) {
              return _ViewAllTile(onTap: _openBrandList);
            }
            final brand = otherBrandData[index];
            return _Reveal(
              index: index,
              child: AppBrandCard(
                brand: brand,
                onTap: () => _navigateToBrandDetail(brand),
              ),
            );
          },
          childCount: otherBrandData.length + 1,
        ),
      ),
    );
  }

  Widget _buildMissingBrandHint() {
    return Center(
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text("Don't see your brand? ", style: AppTextStyles.bodySmall),
          GestureDetector(
            onTap: () => FocusScope.of(context).requestFocus(_searchFocusNode),
            child: Text(
              'Search above',
              style: AppTextStyles.label.copyWith(color: AppColors.primary),
            ),
          ),
        ],
      ),
    );
  }
}

/// Fades and lifts a tile into place, staggered by position.
///
/// The stagger is expressed as an [Interval] on a single tween rather than a
/// delayed start, so no timer is created per tile and nothing is left pending
/// if the screen is popped mid-animation.
class _Reveal extends StatelessWidget {
  const _Reveal({required this.index, required this.child});

  final int index;
  final Widget child;

  static const int _slots = 9;
  static const int _revealMs = 260;
  static const int _stepMs = 40;
  static const int _totalMs = _revealMs + _stepMs * (_slots - 1);

  @override
  Widget build(BuildContext context) {
    final slot = index % _slots;
    final begin = (slot * _stepMs) / _totalMs;
    final end = (slot * _stepMs + _revealMs) / _totalMs;

    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: _totalMs),
      curve: Interval(begin, end, curve: Curves.easeOut),
      child: child,
      builder: (context, value, child) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, (1 - value) * 12),
            child: child,
          ),
        );
      },
    );
  }
}

/// Pinned search bar. Keeps a solid background so content scrolls beneath it
/// cleanly, and grows a hairline rule once it overlaps.
/// Trailing grid cell that opens the full, searchable brand list.
class _ViewAllTile extends StatelessWidget {
  const _ViewAllTile({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'View all brands',
      child: InkWell(
        onTap: onTap,
        borderRadius: AppRadius.card,
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            color: AppColors.primarySoft,
            borderRadius: AppRadius.card,
            border: Border.all(color: AppColors.primary),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.grid_view_rounded,
                size: 26,
                color: AppColors.onPrimarySoft,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'View all',
                textAlign: TextAlign.center,
                style: AppTextStyles.label.copyWith(
                  color: AppColors.onPrimarySoft,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HelpItem {
  const _HelpItem({
    required this.icon,
    required this.question,
    required this.answer,
  });

  final IconData icon;
  final String question;
  final String answer;
}

/// Selling FAQs, opened from the header. One item expands at a time.
class _HelpSheet extends StatefulWidget {
  const _HelpSheet();

  @override
  State<_HelpSheet> createState() => _HelpSheetState();
}

class _HelpSheetState extends State<_HelpSheet> {
  static const List<_HelpItem> _items = [
    _HelpItem(
      icon: Icons.local_shipping_outlined,
      question: 'How does doorstep pickup work?',
      answer: 'Book a free pickup slot; our partner collects your phone, '
          'verifies it instantly, and hands over the payment on the spot.',
    ),
    _HelpItem(
      icon: Icons.currency_rupee,
      question: 'How is my price calculated?',
      answer: 'We check your model, condition and current market demand to '
          'generate an AI-recommended instant quote — no surprises.',
    ),
    _HelpItem(
      icon: Icons.schedule,
      question: 'When will I get paid?',
      answer: 'The moment we verify your device during pickup you receive '
          'payment immediately via UPI or bank transfer.',
    ),
    _HelpItem(
      icon: Icons.phone_android,
      question: 'Which phones are accepted?',
      answer: 'Any smartphone that powers on is eligible — even with cracks, '
          'scratches or a dead battery.',
    ),
  ];

  int? _expandedIndex = 0;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.xl,
          AppSpacing.md,
          AppSpacing.xl,
          AppSpacing.xl,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                height: 4,
                width: 40,
                decoration: BoxDecoration(
                  color: AppColors.border,
                  borderRadius: AppRadius.pill,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Selling help', style: AppTextStyles.h2),
                      const SizedBox(height: 2),
                      Text(
                        'Everything you need to know about selling your phone',
                        style: AppTextStyles.bodySmall,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(
                    Icons.close_rounded,
                    color: AppColors.textSecondary,
                  ),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < _items.length; i++) ...[
                      if (i > 0) const SizedBox(height: AppSpacing.sm),
                      _AccordionItem(
                        item: _items[i],
                        expanded: _expandedIndex == i,
                        onToggle: () => setState(
                          () => _expandedIndex = _expandedIndex == i ? null : i,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AccordionItem extends StatelessWidget {
  const _AccordionItem({
    required this.item,
    required this.expanded,
    required this.onToggle,
  });

  final _HelpItem item;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      decoration: BoxDecoration(
        color: expanded ? AppColors.primarySoft : AppColors.surface,
        borderRadius: AppRadius.card,
        border: Border.all(
          color: expanded ? AppColors.primary : AppColors.border,
        ),
      ),
      child: Material(
        color: AppColors.transparent,
        child: InkWell(
          onTap: onToggle,
          borderRadius: AppRadius.card,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(
                      item.icon,
                      size: 18,
                      color: expanded
                          ? AppColors.onPrimarySoft
                          : AppColors.textSecondary,
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Text(
                        item.question,
                        style: AppTextStyles.bodyMedium,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    AnimatedRotation(
                      turns: expanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: const Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: 20,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
                AnimatedCrossFade(
                  firstChild: const SizedBox(width: double.infinity),
                  secondChild: Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.md),
                    child: Text(item.answer, style: AppTextStyles.bodySmall),
                  ),
                  crossFadeState: expanded
                      ? CrossFadeState.showSecond
                      : CrossFadeState.showFirst,
                  duration: const Duration(milliseconds: 200),
                  sizeCurve: Curves.easeInOut,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One model in the search results: its own photo, its name, its brand.
///
/// The results used to be a generic phone icon beside a hardcoded string,
/// which told a seller nothing about whether the match was the phone in their
/// hand — the thing a photo settles at a glance.
class _ModelResultTile extends StatelessWidget {
  const _ModelResultTile({required this.model, required this.onTap});

  final ModelDetail model;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AppSurface(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      child: Row(
        children: [
          SizedBox(
            height: 44,
            width: 44,
            child: AppNetworkImage(
              url: model.imageUrl ?? '',
              fit: BoxFit.contain,
              borderRadius: BorderRadius.zero,
              placeholderIcon: Icons.smartphone_rounded,
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  model.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.bodyMedium,
                ),
                if (model.brand.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    model.brand.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.overline
                        .copyWith(color: AppColors.textTertiary),
                  ),
                ],
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
    );
  }
}
