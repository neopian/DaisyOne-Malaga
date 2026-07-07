import 'package:flutter/material.dart';

class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.label, this.emphasis = false});

  final String label;
  final bool emphasis;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Chip(
      label: Text(label),
      visualDensity: VisualDensity.compact,
      side: BorderSide.none,
      backgroundColor: emphasis
          ? scheme.primaryContainer
          : scheme.surfaceContainerHighest,
      labelStyle: TextStyle(
        color: emphasis ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}
