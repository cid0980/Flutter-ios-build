import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:share_plus/share_plus.dart';

import '../firebase/catalog_firebase.dart';
import '../screens/biometric_diagnostic_page.dart';
import '../shared/motion/motion.dart';
import '../shared/theme/app_colors.dart';
import '../shared/theme/app_text_styles.dart';
import '../shared/theme/app_theme.dart';
import '../shared/services/reverse_geocoder.dart';
import '../shared/widgets/widgets.dart';
import 'location_picker_page.dart';

// ===========================================================================
// Saved addresses
// ===========================================================================

class SavedAddressesPage extends StatefulWidget {
  final bool selectMode;
  const SavedAddressesPage({super.key, this.selectMode = false});

  @override
  State<SavedAddressesPage> createState() => _SavedAddressesPageState();
}

class _SavedAddressesPageState extends State<SavedAddressesPage> {
  CollectionReference<Map<String, dynamic>>? _addressesRef;
  final TextEditingController _searchController = TextEditingController();
  final ReverseGeocoder _geocoder = ReverseGeocoder();
  String _searchQuery = '';
  bool _fetchingLocation = false;

  /// Subscribed once, in initState. A stream created inside build is a new
  /// listener every frame, and each one bills a fresh read of the whole list.
  Stream<QuerySnapshot<Map<String, dynamic>>>? _addresses;

  Stream<QuerySnapshot<Map<String, dynamic>>> get _addressesStream =>
      _addresses ??=
          _addressesRef!.orderBy('createdAt', descending: true).snapshots();

  @override
  void initState() {
    super.initState();
    final user = catalogAuth.currentUser;
    if (user != null) {
      _addressesRef = catalogFirestore
          .collection('users')
          .doc(user.uid)
          .collection('addresses');
    }
    _searchController.addListener(() {
      setState(() {
        _searchQuery = _searchController.text.trim().toLowerCase();
      });
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _geocoder.dispose();
    super.dispose();
  }

  Future<void> _deleteAddress(String docId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: AppRadius.card),
        title: Text('Delete address', style: AppTextStyles.h3),
        content: Text(
          'Are you sure you want to delete this address?',
          style: AppTextStyles.body,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(
              'Cancel',
              style: AppTextStyles.label
                  .copyWith(color: AppColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              'Delete',
              style: AppTextStyles.label.copyWith(color: AppColors.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      try {
        await _addressesRef!.doc(docId).delete();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Failed to delete address: $e')));
        }
      }
    }
  }

  Future<void> _openAddEdit({
    DocumentSnapshot<Map<String, dynamic>>? doc,
  }) async {
    final saved = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
      ),
      builder: (context) =>
          AddEditAddressSheet(addressRef: _addressesRef!, existing: doc),
    );

    // Opened to pick an address: a newly saved one is almost certainly the
    // one wanted, so return it to the caller instead of leaving the user on
    // a list to hunt for it.
    if (!mounted || !widget.selectMode || saved == null) return;
    Navigator.pop(context, saved);
  }

  Future<void> _useCurrentLocationDirect() async {
    if (_addressesRef == null) return;
    LocationPermission permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text(
                  'Location permission is required to use current location')),
        );
      }
      return;
    }

    setState(() => _fetchingLocation = true);
    try {
      final pos = await Geolocator.getCurrentPosition();
      // The one geocoder, shared with the map picker and the address sheet,
      // so every route into an address produces the same format.
      final found = await _geocoder.lookup(pos.latitude, pos.longitude);
      final addressStr = found ??
          ReverseGeocoder.describeCoordinates(pos.latitude, pos.longitude);

      if (!mounted) return;
      setState(() => _fetchingLocation = false);

      final saved = await showModalBottomSheet<Map<String, dynamic>>(
        context: context,
        isScrollControlled: true,
        backgroundColor: AppColors.surface,
        shape: const RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
        ),
        builder: (context) => AddEditAddressSheet(
          addressRef: _addressesRef!,
          prefillAddress: addressStr,
          prefillLatitude: pos.latitude,
          prefillLongitude: pos.longitude,
        ),
      );

      if (!mounted || !widget.selectMode || saved == null) return;
      Navigator.pop(context, saved);
    } catch (e) {
      if (mounted) {
        setState(() => _fetchingLocation = false);
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Unable to fetch location: $e')));
      }
    }
  }

  void _requestFromFriend() {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Coming soon')));
  }

  void _shareAddress(String label, String fullAddress) {
    final box = context.findRenderObject() as RenderBox?;
    final origin = box != null
        ? box.localToGlobal(Offset.zero) & box.size
        : const Rect.fromLTWH(0, 0, 100, 100);
    SharePlus.instance.share(
      ShareParams(
        text: '$label: $fullAddress',
        sharePositionOrigin: origin,
      ),
    );
  }

  Future<void> _setAsDefault(String docId) async {
    if (_addressesRef == null) return;
    try {
      final batch = catalogFirestore.batch();
      final snap = await _addressesRef!.get();
      for (final d in snap.docs) {
        batch.update(d.reference, {'isDefault': d.id == docId});
      }
      await batch.commit();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to set default: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final signedIn = catalogAuth.currentUser != null;

    return Theme(
      data: AppTheme.light,
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: SafeArea(
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
                  title: widget.selectMode
                      ? 'Select address'
                      : 'Saved addresses',
                  content: signedIn
                      ? AppSearchField(
                          controller: _searchController,
                          hintText: 'Search saved addresses',
                        )
                      : null,
                ),
              ),
              Expanded(
                child: signedIn
                    ? _buildBody()
                    : const Padding(
                        padding: EdgeInsets.all(AppSpacing.screenGutter),
                        child: AppEmptyState(
                          title: 'Sign in to manage addresses',
                          message:
                              'Your saved pickup addresses will appear here.',
                          icon: Icons.location_on_outlined,
                        ),
                      ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: signedIn
            ? AppBottomBar(
                child: AppPrimaryButton(
                  label: 'Add new address',
                  icon: Icons.add_rounded,
                  onPressed: () => _openAddEdit(),
                ),
              )
            : null,
      ),
    );
  }

  Widget _buildBody() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.screenGutter,
        0,
        AppSpacing.screenGutter,
        AppSpacing.xxl,
      ),
      children: [
        _buildQuickActions(),
        const SizedBox(height: AppSpacing.xl),
        Text('Saved addresses', style: AppTextStyles.h3),
        const SizedBox(height: AppSpacing.md),
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: _addressesStream,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return AppEmptyState(
                title: 'Could not load addresses',
                message: '${snapshot.error}',
                icon: Icons.wifi_off_rounded,
              );
            }
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Column(
                children: [
                  AppShimmer(width: double.infinity, height: 96),
                  SizedBox(height: AppSpacing.md),
                  AppShimmer(width: double.infinity, height: 96),
                ],
              );
            }

            var docs = snapshot.data?.docs ?? [];
            docs.sort((a, b) {
              final aDef = a.data()['isDefault'] == true;
              final bDef = b.data()['isDefault'] == true;
              if (aDef && !bDef) return -1;
              if (!aDef && bDef) return 1;
              return 0;
            });

            if (_searchQuery.isNotEmpty) {
              docs = docs.where((d) {
                final data = d.data();
                final label = (data['label'] as String? ?? '').toLowerCase();
                final full =
                    (data['fullAddress'] as String? ?? '').toLowerCase();
                return label.contains(_searchQuery) ||
                    full.contains(_searchQuery);
              }).toList();
            }

            if (docs.isEmpty) {
              return AppEmptyState(
                title: _searchQuery.isEmpty
                    ? 'No saved addresses'
                    : 'No matching addresses',
                message: _searchQuery.isEmpty
                    ? 'Add an address so we know where to collect from.'
                    : 'Try a different search.',
                icon: Icons.location_off_outlined,
              );
            }

            return Column(
              children: [
                for (var i = 0; i < docs.length; i++) ...[
                  if (i > 0) const SizedBox(height: AppSpacing.md),
                  AppReveal(index: i, child: _buildAddressCard(docs[i])),
                ],
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _buildQuickActions() {
    return Column(
      children: [
        _ActionTile(
          icon: Icons.my_location_rounded,
          title: 'Use my current location',
          subtitle: 'Detect your address automatically',
          busy: _fetchingLocation,
          onTap: _fetchingLocation ? null : _useCurrentLocationDirect,
        ),
        const SizedBox(height: AppSpacing.sm),
        _ActionTile(
          icon: Icons.people_outline_rounded,
          title: 'Request address from a friend',
          subtitle: 'Send a link to collect their address',
          onTap: _requestFromFriend,
        ),
      ],
    );
  }

  Widget _buildAddressCard(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data()!;
    final label = (data['label'] as String?) ?? 'Other';
    final fullAddress = (data['fullAddress'] as String?) ?? '';
    final isDefault = data['isDefault'] == true;

    return InkWell(
      onTap: widget.selectMode
          ? () {
              Navigator.pop(context, {
                'id': doc.id,
                'label': label,
                'fullAddress': fullAddress,
                'latitude': data['latitude'],
                'longitude': data['longitude'],
              });
            }
          : () => _openAddEdit(doc: doc),
      borderRadius: AppRadius.card,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.lg),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: AppRadius.card,
          border: Border.all(
            color: isDefault ? AppColors.primary : AppColors.border,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _iconForLabel(label),
                  size: 18,
                  color: AppColors.textSecondary,
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(label, style: AppTextStyles.bodyMedium),
                if (isDefault) ...[
                  const SizedBox(width: AppSpacing.sm),
                  const AppBadge(label: 'DEFAULT', tone: AppBadgeTone.primary),
                ],
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(fullAddress, style: AppTextStyles.bodySmall),
            if (!widget.selectMode) ...[
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
                child:
                    Divider(height: 1, thickness: 1, color: AppColors.border),
              ),
              Row(
                children: [
                  if (!isDefault)
                    _CardAction(
                      icon: Icons.check_circle_outline_rounded,
                      label: 'Set default',
                      onTap: () => _setAsDefault(doc.id),
                    ),
                  _CardAction(
                    icon: Icons.share_outlined,
                    label: 'Share',
                    onTap: () => _shareAddress(label, fullAddress),
                  ),
                  const Spacer(),
                  _CardAction(
                    icon: Icons.delete_outline_rounded,
                    label: 'Delete',
                    destructive: true,
                    onTap: () => _deleteAddress(doc.id),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  static IconData _iconForLabel(String label) {
    switch (label.toLowerCase()) {
      case 'home':
        return Icons.home_outlined;
      case 'work':
        return Icons.work_outline_rounded;
      default:
        return Icons.location_on_outlined;
    }
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.busy = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: AppRadius.card,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.lg),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: AppRadius.card,
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Container(
              height: 36,
              width: 36,
              decoration: const BoxDecoration(
                color: AppColors.primarySoft,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: busy
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(icon, size: 18, color: AppColors.onPrimarySoft),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title, style: AppTextStyles.bodyMedium),
                  const SizedBox(height: 2),
                  Text(subtitle, style: AppTextStyles.caption),
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
    );
  }
}

class _CardAction extends StatelessWidget {
  const _CardAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final color = destructive ? AppColors.error : AppColors.textSecondary;

    return TextButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 16, color: color),
      label: Text(label, style: AppTextStyles.caption.copyWith(color: color)),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
        minimumSize: const Size(0, 32),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}

// ===========================================================================
// Add / edit address sheet
// ===========================================================================

class AddEditAddressSheet extends StatefulWidget {
  final CollectionReference<Map<String, dynamic>> addressRef;
  final DocumentSnapshot<Map<String, dynamic>>? existing;
  final String? prefillAddress;
  final double? prefillLatitude;
  final double? prefillLongitude;

  const AddEditAddressSheet({
    super.key,
    required this.addressRef,
    this.existing,
    this.prefillAddress,
    this.prefillLatitude,
    this.prefillLongitude,
  });

  @override
  State<AddEditAddressSheet> createState() => _AddEditAddressSheetState();
}

class _AddEditAddressSheetState extends State<AddEditAddressSheet> {
  static const List<String> _labels = ['Home', 'Work', 'Other'];

  String _label = 'Home';
  final TextEditingController _addressController = TextEditingController();
  final ReverseGeocoder _geocoder = ReverseGeocoder();
  double? _latitude;
  double? _longitude;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    if (widget.existing != null) {
      final d = widget.existing!.data()!;
      _label = (d['label'] as String?) ?? 'Other';
      _addressController.text = (d['fullAddress'] as String?) ?? '';
      _latitude = (d['latitude'] as num?)?.toDouble();
      _longitude = (d['longitude'] as num?)?.toDouble();
    } else if (widget.prefillAddress != null) {
      _addressController.text = widget.prefillAddress!;
      _latitude = widget.prefillLatitude;
      _longitude = widget.prefillLongitude;
    }
  }

  @override
  void dispose() {
    _addressController.dispose();
    _geocoder.dispose();
    super.dispose();
  }

  /// Opens the map on whatever point this address already has, so editing
  /// one nudges an existing pin rather than starting from nothing.
  Future<void> _pickOnMap() async {
    final picked = await Navigator.of(context).push<PickedLocation>(
      MaterialPageRoute(
        builder: (_) => LocationPickerPage(
          initialLatitude: _latitude,
          initialLongitude: _longitude,
        ),
      ),
    );
    if (!mounted || picked == null) return;

    setState(() {
      _latitude = picked.latitude;
      _longitude = picked.longitude;
      _addressController.text = picked.address;
    });
  }

  Future<void> _useCurrentLocation() async {
    LocationPermission permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Location permission is required to use current location')));
      }
      return;
    }

    try {
      final pos = await Geolocator.getCurrentPosition();
      // Same geocoder the map picker uses, so both routes produce addresses
      // in the same format.
      final found = await _geocoder.lookup(pos.latitude, pos.longitude);
      if (!mounted) return;

      setState(() {
        _latitude = pos.latitude;
        _longitude = pos.longitude;
        _addressController.text = found ??
            ReverseGeocoder.describeCoordinates(pos.latitude, pos.longitude);
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Unable to fetch location: $e')));
      }
    }
  }

  Future<void> _save() async {
    final text = _addressController.text.trim();
    if (text.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Enter an address')));
      }
      return;
    }
    setState(() => _saving = true);

    try {
      String savedId;

      if (widget.existing == null) {
        final snapshot = await widget.addressRef.get();
        final first = snapshot.docs.isEmpty;
        final ref = await widget.addressRef.add({
          'label': _label,
          'fullAddress': text,
          'latitude': _latitude,
          'longitude': _longitude,
          'isDefault': first,
          'createdAt': FieldValue.serverTimestamp(),
        });
        savedId = ref.id;
      } else {
        savedId = widget.existing!.id;
        await widget.addressRef.doc(savedId).update({
          'label': _label,
          'fullAddress': text,
          'latitude': _latitude,
          'longitude': _longitude,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }

      // Hand the saved address back rather than popping empty, so a caller
      // picking an address can use it immediately instead of sending the user
      // back to a list to find what they just typed. Same key shape the list
      // returns in selectMode. Nothing about the write itself changed.
      if (mounted) {
        Navigator.pop(context, <String, dynamic>{
          'id': savedId,
          'label': _label,
          'fullAddress': text,
          'latitude': _latitude,
          'longitude': _longitude,
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to save address: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;

    return Theme(
      data: AppTheme.light,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SafeArea(
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
                Text(
                  isEdit ? 'Edit address' : 'Add address',
                  style: AppTextStyles.h2,
                ),
                const SizedBox(height: AppSpacing.xl),
                Text('Label', style: AppTextStyles.label),
                const SizedBox(height: AppSpacing.sm),
                Row(
                  children: [
                    for (var i = 0; i < _labels.length; i++) ...[
                      if (i > 0) const SizedBox(width: AppSpacing.sm),
                      AppFilterChip(
                        label: _labels[i],
                        selected: _label == _labels[i],
                        onTap: () => setState(() => _label = _labels[i]),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: AppSpacing.xl),
                Text('Full address', style: AppTextStyles.label),
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  controller: _addressController,
                  maxLines: 3,
                  style: AppTextStyles.body,
                  decoration: const InputDecoration(
                    hintText: 'House number, street, area, city, pincode',
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                // Two ways in, because they answer different questions: the
                // map is for "somewhere else", current location for "here".
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _pickOnMap,
                        icon: const Icon(Icons.map_outlined, size: 18),
                        label: const Text('Pick on map'),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _useCurrentLocation,
                        icon: const Icon(Icons.my_location_rounded, size: 18),
                        label: const Text('Use my location'),
                      ),
                    ),
                  ],
                ),
                if (_latitude != null && _longitude != null) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Row(
                    children: [
                      const Icon(Icons.place_outlined,
                          size: 14, color: AppColors.success),
                      const SizedBox(width: AppSpacing.xs),
                      Expanded(
                        child: Text(
                          'Pinned at '
                          '${ReverseGeocoder.describeCoordinates(_latitude!, _longitude!)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyles.caption,
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: AppSpacing.xl),
                AppPrimaryButton(
                  label: isEdit ? 'Save changes' : 'Save address',
                  loading: _saving,
                  onPressed: _saving ? null : _save,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ===========================================================================
// Static / preference pages
// ===========================================================================

/// Shared scaffold for the simpler account pages.
class _AccountScaffold extends StatelessWidget {
  const _AccountScaffold({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: AppTheme.light,
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.screenGutter,
              AppSpacing.lg,
              AppSpacing.screenGutter,
              AppSpacing.xxl,
            ),
            children: [
              AppScreenHeader(title: title),
              const SizedBox(height: AppSpacing.xl),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

/// A card wrapping a list of rows separated by hairlines.
class _Card extends StatelessWidget {
  const _Card({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.card,
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0)
              const Divider(
                height: 1,
                thickness: 1,
                indent: AppSpacing.lg,
                endIndent: AppSpacing.lg,
                color: AppColors.border,
              ),
            children[i],
          ],
        ],
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.sm,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: AppTextStyles.bodyMedium),
                const SizedBox(height: 2),
                Text(subtitle, style: AppTextStyles.caption),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: AppColors.onPrimary,
            activeTrackColor: AppColors.primary,
          ),
        ],
      ),
    );
  }
}

class NotificationPreferencesPage extends StatefulWidget {
  const NotificationPreferencesPage({super.key});

  @override
  State<NotificationPreferencesPage> createState() =>
      _NotificationPreferencesPageState();
}

class _NotificationPreferencesPageState
    extends State<NotificationPreferencesPage> {
  bool orderUpdates = true;
  bool priceAlerts = true;
  bool promoOffers = false;
  bool whatsappUpdates = true;

  @override
  Widget build(BuildContext context) {
    return _AccountScaffold(
      title: 'Notifications',
      children: [
        _Card(
          children: [
            _SwitchRow(
              title: 'Order updates',
              subtitle: 'Pickup, inspection and payment alerts',
              value: orderUpdates,
              onChanged: (v) => setState(() => orderUpdates = v),
            ),
            _SwitchRow(
              title: 'Price alerts',
              subtitle: 'When your device value changes',
              value: priceAlerts,
              onChanged: (v) => setState(() => priceAlerts = v),
            ),
            _SwitchRow(
              title: 'Offers & promotions',
              subtitle: 'Occasional deals and bonus payouts',
              value: promoOffers,
              onChanged: (v) => setState(() => promoOffers = v),
            ),
            _SwitchRow(
              title: 'WhatsApp updates',
              subtitle: 'Get the same alerts on WhatsApp',
              value: whatsappUpdates,
              onChanged: (v) => setState(() => whatsappUpdates = v),
            ),
          ],
        ),
      ],
    );
  }
}

class PrivacySecurityPage extends StatefulWidget {
  const PrivacySecurityPage({super.key});

  @override
  State<PrivacySecurityPage> createState() => _PrivacySecurityPageState();
}

class _PrivacySecurityPageState extends State<PrivacySecurityPage> {
  bool biometrics = true;

  @override
  Widget build(BuildContext context) {
    return _AccountScaffold(
      title: 'Privacy & security',
      children: [
        _Card(
          children: [
            _SwitchRow(
              title: 'Biometric unlock',
              subtitle: 'Use fingerprint or face to open the app',
              value: biometrics,
              onChanged: (v) => setState(() => biometrics = v),
            ),
            AppListTile(
              title: 'Biometric sensor diagnostic',
              subtitle: 'Test Face ID, Touch ID or fingerprint hardware',
              leadingIcon: Icons.fingerprint_rounded,
              onTap: () => context.pushScreen<bool>(
                const BiometricDiagnosticPage(),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        _Card(
          children: [
            AppListTile(
              title: 'Data wipe guarantee',
              subtitle: 'How we erase your device at pickup',
              leadingIcon: Icons.delete_sweep_outlined,
              onTap: () {},
            ),
            AppListTile(
              title: 'Privacy policy',
              leadingIcon: Icons.policy_outlined,
              onTap: () {},
            ),
          ],
        ),
      ],
    );
  }
}

class HelpCenterPage extends StatelessWidget {
  const HelpCenterPage({super.key});

  @override
  Widget build(BuildContext context) {
    return _AccountScaffold(
      title: 'Help centre',
      children: [
        const AppSearchField(
          hintText: 'Search for issues, orders, payments…',
        ),
        const SizedBox(height: AppSpacing.xl),
        Text('Browse topics', style: AppTextStyles.h3),
        const SizedBox(height: AppSpacing.md),
        _Card(
          children: [
            AppListTile(
              title: 'Orders & pickup',
              leadingIcon: Icons.local_shipping_outlined,
              onTap: () {},
            ),
            AppListTile(
              title: 'Payments & payouts',
              leadingIcon: Icons.payments_outlined,
              onTap: () {},
            ),
            AppListTile(
              title: 'Pricing & valuation',
              leadingIcon: Icons.trending_up_rounded,
              onTap: () {},
            ),
            AppListTile(
              title: 'Account & privacy',
              leadingIcon: Icons.lock_outline_rounded,
              onTap: () {},
            ),
          ],
        ),
      ],
    );
  }
}

class AboutUsPage extends StatelessWidget {
  const AboutUsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return _AccountScaffold(
      title: 'About us',
      children: [
        Center(
          child: Column(
            children: [
              Container(
                height: 80,
                width: 80,
                decoration: const BoxDecoration(
                  color: AppColors.primarySoft,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: const Icon(
                  Icons.phonelink_setup_rounded,
                  size: 36,
                  color: AppColors.onPrimarySoft,
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text('TradeIn Express', style: AppTextStyles.h1),
              const SizedBox(height: AppSpacing.xs),
              Text('Version 1.0.0', style: AppTextStyles.caption),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xxl),
        Text(
          'We buy and resell pre-owned phones at a fair, transparent price — '
          'with free doorstep pickup and instant payment.',
          textAlign: TextAlign.center,
          style: AppTextStyles.body.copyWith(color: AppColors.textSecondary),
        ),
      ],
    );
  }
}
