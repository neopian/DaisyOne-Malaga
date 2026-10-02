import 'package:flutter/material.dart';

class StatusChip extends StatelessWidget {
  const StatusChip({
    super.key,
    required this.label,
    this.emphasis = false,
    this.compact = false,
  });

  final String label;
  final bool emphasis;
  final bool compact;

  String get _displayLabel =>
      const {
        'open': '답변자 기다리는 중',
        'assigned': '답변 준비 중',
        'answered': '답변 도착',
        'accepted': '채택 완료',
        'cancelled': '취소됨',
        'expired': '기한 종료',
      }[label] ??
      label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final backgroundColor = emphasis
        ? scheme.primaryContainer
        : scheme.surfaceContainerHighest;
    final foregroundColor = emphasis
        ? scheme.onPrimaryContainer
        : scheme.onSurfaceVariant;

    if (compact) {
      return Container(
        constraints: const BoxConstraints(minHeight: 28),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          _displayLabel,
          maxLines: 2,
          softWrap: true,
          style: TextStyle(
            color: foregroundColor,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      );
    }

    return Chip(
      label: Text(_displayLabel),
      visualDensity: VisualDensity.compact,
      side: BorderSide.none,
      backgroundColor: backgroundColor,
      labelStyle: TextStyle(
        color: foregroundColor,
        fontWeight: FontWeight.w500,
      ),
    );
  }
}
