import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../shared/theme/app_colors.dart';
import '../../shared/theme/app_text_styles.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/widgets.dart';

/// One permission the checkup needs, and why — in words a seller understands.
class CheckupPermissionNeed {
  const CheckupPermissionNeed({
    required this.permission,
    required this.icon,
    required this.label,
    required this.reason,
  });

  final Permission permission;
  final IconData icon;
  final String label;

  /// What it is for. Android shows its own terse prompt; this is the sentence
  /// that makes the prompt make sense before it appears.
  final String reason;
}

/// Every permission the checkup asks for, gathered in one place.
///
/// The tests used to each request their own on first frame, so a full run
/// interrupted the user five separate times, several tests in. Asking once up
/// front is what every other app does, and it means a denial is discovered
/// before the run starts rather than halfway through it.
class CheckupPermissions {
  CheckupPermissions._();

  static const List<CheckupPermissionNeed> needs = [
    CheckupPermissionNeed(
      permission: Permission.camera,
      icon: Icons.photo_camera_outlined,
      label: 'Camera',
      reason: 'To preview both cameras and drive the torch.',
    ),
    CheckupPermissionNeed(
      permission: Permission.microphone,
      icon: Icons.mic_none_outlined,
      label: 'Microphone',
      reason: 'To record a moment of sound and measure what came back.',
    ),
    CheckupPermissionNeed(
      permission: Permission.location,
      icon: Icons.my_location_outlined,
      label: 'Location',
      reason: 'For the GPS fix, and because Android requires it to scan '
          'for Wi-Fi and Bluetooth.',
    ),
    CheckupPermissionNeed(
      permission: Permission.nearbyWifiDevices,
      icon: Icons.wifi,
      label: 'Nearby Wi-Fi',
      reason: 'To list the networks the radio can see.',
    ),
    CheckupPermissionNeed(
      permission: Permission.bluetoothScan,
      icon: Icons.bluetooth_searching,
      label: 'Bluetooth scan',
      reason: 'To find nearby devices and prove the radio works.',
    ),
    CheckupPermissionNeed(
      permission: Permission.bluetoothConnect,
      icon: Icons.bluetooth_connected,
      label: 'Bluetooth',
      reason: 'To read the adapter state and switch it on.',
    ),
    CheckupPermissionNeed(
      permission: Permission.phone,
      icon: Icons.sim_card_outlined,
      label: 'Phone',
      reason: 'To read the SIM and carrier for the mobile network test.',
    ),
  ];

  /// The needs that would actually prompt, i.e. not already granted.
  ///
  /// A permission the user has permanently denied is not listed: asking again
  /// shows nothing at all, so promising a prompt would be a lie. Those surface
  /// on the test itself, which offers a route to system settings.
  static Future<List<CheckupPermissionNeed>> outstanding() async {
    final isIOS = defaultTargetPlatform == TargetPlatform.iOS;
    final result = <CheckupPermissionNeed>[];
    for (final need in needs) {
      try {
        if (isIOS) {
          // Android-only permissions that have no iOS prompt.
          if (need.permission == Permission.nearbyWifiDevices ||
              need.permission == Permission.phone ||
              need.permission == Permission.bluetoothScan) {
            continue;
          }
          if (need.permission == Permission.bluetoothConnect) {
            final btStatus = await Permission.bluetooth.status;
            if (!btStatus.isGranted && !btStatus.isPermanentlyDenied) {
              result.add(CheckupPermissionNeed(
                permission: Permission.bluetooth,
                icon: need.icon,
                label: need.label,
                reason: need.reason,
              ));
            }
            continue;
          }
        }
        final status = await need.permission.status;
        if (!status.isGranted && !status.isPermanentlyDenied) {
          result.add(need);
        }
      } catch (_) {
        // Not every permission exists on every platform, and querying an
        // absent one throws. Leaving it out means the run is not blocked by a
        // permission this device does not have; the test that wants it still
        // asks for itself, which is what happened before any of this existed.
      }
    }
    return result;
  }

  /// Asks for everything in one uninterrupted run of system prompts.
  ///
  /// A failure here is not fatal for the same reason: each test still
  /// requests what it needs, so the worst case is the old behaviour.
  static Future<Map<Permission, PermissionStatus>> requestAll() async {
    try {
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        return await [
          Permission.camera,
          Permission.microphone,
          Permission.location,
          Permission.bluetooth,
        ].request();
      }
      return await needs.map((n) => n.permission).toList().request();
    } catch (_) {
      return const {};
    }
  }
}

/// The "here is what we are about to ask for" sheet.
///
/// Shown before the system prompts rather than instead of them: Android's own
/// dialogs are terse and give no room to explain, and a seller who does not
/// know why a buyback app wants their microphone denies it.
///
/// Returns true if the user chose to continue.
Future<bool> showCheckupPermissionSheet(
  BuildContext context,
  List<CheckupPermissionNeed> needs,
) async {
  final accepted = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: AppColors.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
    ),
    builder: (context) => _CheckupPermissionSheet(needs: needs),
  );
  return accepted ?? false;
}

class _CheckupPermissionSheet extends StatelessWidget {
  const _CheckupPermissionSheet({required this.needs});

  final List<CheckupPermissionNeed> needs;

  @override
  Widget build(BuildContext context) {
    final osName =
        defaultTargetPlatform == TargetPlatform.iOS ? 'iOS' : 'Android';
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.screenGutter,
          AppSpacing.xl,
          AppSpacing.screenGutter,
          AppSpacing.lg + MediaQuery.paddingOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Before we start', style: AppTextStyles.h2),
            const SizedBox(height: AppSpacing.xs),
            Text(
              needs.length == 1
                  ? 'The checkup needs one permission. $osName will ask you '
                      'for it next.'
                  : 'The checkup needs ${needs.length} permissions. $osName '
                      'will ask for them one after another.',
              style: AppTextStyles.bodySmall,
            ),
            const SizedBox(height: AppSpacing.lg),
            Flexible(
              child: SingleChildScrollView(
                child: AppGroup(
                  children: [
                    for (final need in needs) _NeedRow(need: need),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            AppPrimaryButton(
              label: 'Continue',
              onPressed: () => Navigator.of(context).pop(true),
            ),
            Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(
                  'Not now',
                  style: AppTextStyles.button
                      .copyWith(color: AppColors.textSecondary),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NeedRow extends StatelessWidget {
  const _NeedRow({required this.need});

  final CheckupPermissionNeed need;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 32,
            width: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.primarySoft,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Icon(need.icon, size: 17, color: AppColors.onPrimarySoft),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(need.label, style: AppTextStyles.bodyMedium),
                const SizedBox(height: 2),
                Text(need.reason, style: AppTextStyles.caption),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
