import 'package:flutter/material.dart';

/// One rounded hit/hover surface for settings navigation, including its icon.
class SettingsNavigationRow extends StatelessWidget {
  const SettingsNavigationRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: Colors.transparent,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          shape: shape,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 2,
          ),
          minLeadingWidth: 24,
          horizontalTitleGap: 12,
          leading: Icon(icon, size: 23),
          title: Text(title),
          subtitle: Text(subtitle),
          trailing: const Icon(Icons.chevron_right, size: 21),
          hoverColor: scheme.primary.withValues(alpha: .055),
          splashColor: scheme.primary.withValues(alpha: .075),
          onTap: onTap,
        ),
      ),
    );
  }
}
