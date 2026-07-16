import 'package:flutter/material.dart';

import '../../../data/models/client_chore.dart';
import '../../../ui/calee_theme.dart';
import '../../../ui/calee_widgets.dart';
import '../chore_grouping.dart';

class ChoreRow extends StatelessWidget {
  const ChoreRow({
    required this.chore,
    required this.calendarName,
    required this.scheduledLabel,
    required this.isUpdating,
    this.onToggleCompletion,
    this.onCircleTap,
    this.onMoreTap,
    this.onRowTap,
    super.key,
  });

  final ClientChore chore;
  final String calendarName;
  final String scheduledLabel;
  final bool isUpdating;
  final VoidCallback? onToggleCompletion;
  final VoidCallback? onCircleTap;
  final VoidCallback? onMoreTap;
  final VoidCallback? onRowTap;

  @override
  Widget build(BuildContext context) {
    final isDone =
        chore.completedToday || chore.normalizedSection == 'doneToday';
    final isHistory =
        chore.isCompletionLog || chore.normalizedSection == 'history';

    final subtitleParts = choreSubtitleParts(
      chore: chore,
      calendarName: calendarName,
      scheduledLabel: scheduledLabel,
    );
    final subtitle = subtitleParts.where((p) => p.isNotEmpty).join(' · ');

    Widget leading;
    if (isHistory) {
      leading = const Icon(
        Icons.history_outlined,
        size: 22,
        color: CaleeColors.textTertiary,
      );
    } else {
      final effectiveCircleTap = onCircleTap ?? onToggleCompletion;
      leading = Semantics(
        label: onCircleTap != null
            ? 'View chore actions'
            : isDone
            ? 'Mark chore not complete'
            : 'Mark chore complete',
        button: true,
        excludeSemantics: true,
        child: CaleeCheckCircle(
          key: ValueKey('chore_toggle_${chore.id}'),
          isChecked: isDone,
          onTap: effectiveCircleTap,
          isLoading: isUpdating,
          size: 22,
        ),
      );
    }

    Widget? trailing;
    final showMore = onMoreTap != null;
    if (chore.points > 0 || showMore) {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (chore.points > 0) _PointsBadge(chore.points),
          if (showMore) ...[
            const SizedBox(width: CaleeSpacing.xs),
            SizedBox(
              width: 28,
              height: 28,
              child: IconButton(
                key: ValueKey('chore_more_${chore.id}'),
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.more_horiz, size: 18),
                color: CaleeColors.textTertiary,
                onPressed: onMoreTap,
              ),
            ),
          ],
        ],
      );
    }

    TextStyle? titleStyle;
    if (isDone) {
      titleStyle = const TextStyle(
        color: CaleeColors.textTertiary,
        decoration: TextDecoration.lineThrough,
        decorationColor: CaleeColors.textTertiary,
      );
    } else if (isHistory) {
      titleStyle = const TextStyle(color: CaleeColors.textTertiary);
    }

    final effectiveTrailing =
        trailing ??
        (onToggleCompletion != null || onCircleTap != null
            ? const SizedBox.shrink()
            : null);

    return CaleeListRow(
      leading: leading,
      title: chore.title,
      subtitle: subtitle.isNotEmpty ? subtitle : null,
      trailing: effectiveTrailing,
      titleStyle: titleStyle,
      onTap: onRowTap,
    );
  }
}

class _PointsBadge extends StatelessWidget {
  const _PointsBadge(this.points);

  final int points;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: CaleeColors.primary.withAlpha(CaleeAlpha.pct8),
        borderRadius: BorderRadius.circular(CaleeRadius.dot),
      ),
      child: Text(
        '$points ${points == 1 ? 'star' : 'stars'}',
        style: const TextStyle(
          fontSize: 11,
          color: CaleeColors.primary,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
