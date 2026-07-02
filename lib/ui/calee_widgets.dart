import 'package:flutter/material.dart';

import 'calee_theme.dart';

// ─────────────────────────────────────────────
// CaleeScaffold
// ─────────────────────────────────────────────

/// Standard Calee page scaffold. Wraps [Scaffold] with the shared grouped
/// background colour and consistent safe-area handling. Accepts an optional
/// [floatingActionButton] and [bottomNavigationBar] forwarded unchanged.
class CaleeScaffold extends StatelessWidget {
  const CaleeScaffold({
    required this.body,
    this.appBar,
    this.floatingActionButton,
    this.bottomNavigationBar,
    super.key,
  });

  final PreferredSizeWidget? appBar;
  final Widget body;
  final Widget? floatingActionButton;
  final Widget? bottomNavigationBar;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: CaleeColors.scaffoldBackground,
      appBar: appBar,
      floatingActionButton: floatingActionButton,
      bottomNavigationBar: bottomNavigationBar,
      body: body,
    );
  }
}

// ─────────────────────────────────────────────
// CaleeSection
// ─────────────────────────────────────────────

/// A grouped section card styled like iOS grouped table view sections.
/// Shows an optional [title] above and optional [footer] below the card.
class CaleeSection extends StatelessWidget {
  const CaleeSection({
    required this.children,
    this.title,
    this.trailing,
    this.footer,
    super.key,
  });

  final String? title;
  final String? trailing;
  final String? footer;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null || trailing != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              CaleeSpacing.sm,
              0,
              CaleeSpacing.sm,
              CaleeSpacing.xs,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                if (title != null)
                  Text(
                    title!.toUpperCase(),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: CaleeColors.textSecondary,
                      letterSpacing: 0.5,
                    ),
                  ),
                if (trailing != null)
                  Text(
                    trailing!,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: CaleeColors.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
        Container(
          decoration: BoxDecoration(
            color: CaleeColors.surface,
            borderRadius: BorderRadius.circular(CaleeRadius.card),
          ),
          clipBehavior: Clip.hardEdge,
          child: Column(children: _intersperse(children)),
        ),
        if (footer != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              CaleeSpacing.sm,
              CaleeSpacing.xs,
              CaleeSpacing.sm,
              0,
            ),
            child: Text(
              footer!,
              style: theme.textTheme.labelSmall?.copyWith(
                color: CaleeColors.textSecondary,
              ),
            ),
          ),
      ],
    );
  }

  List<Widget> _intersperse(List<Widget> items) {
    if (items.length <= 1) return items;
    final result = <Widget>[];
    for (var i = 0; i < items.length; i++) {
      result.add(items[i]);
      if (i < items.length - 1) {
        result.add(const Divider(indent: CaleeSpacing.md, endIndent: 0));
      }
    }
    return result;
  }
}

// ─────────────────────────────────────────────
// CaleeListRow
// ─────────────────────────────────────────────

/// A single row inside a [CaleeSection]. Provides consistent padding, leading
/// widget, title, optional subtitle and optional trailing widget.
class CaleeListRow extends StatelessWidget {
  const CaleeListRow({
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.titleStyle,
    this.subtitleStyle,
    this.enabled = true,
    super.key,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final TextStyle? titleStyle;
  final TextStyle? subtitleStyle;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: CaleeSpacing.md,
          vertical: 11,
        ),
        child: Row(
          children: [
            if (leading != null) ...[
              leading!,
              const SizedBox(width: CaleeSpacing.md),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style:
                        titleStyle ??
                        theme.textTheme.bodyLarge?.copyWith(
                          color: enabled
                              ? CaleeColors.textPrimary
                              : CaleeColors.textTertiary,
                        ),
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        subtitle!,
                        style:
                            subtitleStyle ??
                            theme.textTheme.bodySmall?.copyWith(
                              color: CaleeColors.textSecondary,
                            ),
                      ),
                    ),
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: CaleeSpacing.sm),
              trailing!,
            ] else if (onTap != null)
              const Icon(
                Icons.chevron_right,
                color: CaleeColors.textTertiary,
                size: 20,
              ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// CaleeBottomSheet
// ─────────────────────────────────────────────

/// Standard Calee modal bottom sheet chrome: drag handle, title, keyboard
/// inset padding, and safe-area support. Wrap form content in [child].
class CaleeBottomSheet extends StatelessWidget {
  const CaleeBottomSheet({
    required this.title,
    required this.child,
    this.showHandle = true,
    super.key,
  });

  final String title;
  final Widget child;
  final bool showHandle;

  /// Convenience: shows a [CaleeBottomSheet] via [showModalBottomSheet].
  static Future<T?> show<T>({
    required BuildContext context,
    required String title,
    required Widget child,
  }) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      backgroundColor: CaleeColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(CaleeRadius.sheet),
        ),
      ),
      builder: (_) => CaleeBottomSheet(title: title, child: child),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final theme = Theme.of(context);

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          CaleeSpacing.md,
          CaleeSpacing.sm,
          CaleeSpacing.md,
          CaleeSpacing.md + bottomInset,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showHandle)
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: CaleeSpacing.md),
                  decoration: BoxDecoration(
                    color: CaleeColors.separatorOpaque,
                    borderRadius: BorderRadius.circular(CaleeRadius.dot),
                  ),
                ),
              ),
            Row(
              children: [
                Expanded(child: Text(title, style: theme.textTheme.titleLarge)),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).maybePop(),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
            const SizedBox(height: CaleeSpacing.md),
            Flexible(child: child),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// CaleeActionSheet
// ─────────────────────────────────────────────

/// A labelled action in a [CaleeActionSheet].
class CaleeAction {
  const CaleeAction({
    required this.label,
    required this.onTap,
    this.icon,
    this.isDestructive = false,
  });

  final String label;
  final VoidCallback onTap;
  final IconData? icon;
  final bool isDestructive;
}

/// Calee-style action sheet. Shows a list of [CaleeAction]s in a modal bottom
/// sheet with an optional [title]. Automatically adds a Cancel row.
class CaleeActionSheet extends StatelessWidget {
  const CaleeActionSheet({required this.actions, this.title, super.key});

  final String? title;
  final List<CaleeAction> actions;

  static Future<void> show({
    required BuildContext context,
    required List<CaleeAction> actions,
    String? title,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => CaleeActionSheet(title: title, actions: actions),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(CaleeSpacing.sm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              decoration: BoxDecoration(
                color: CaleeColors.surface,
                borderRadius: BorderRadius.circular(CaleeRadius.card),
              ),
              clipBehavior: Clip.hardEdge,
              child: Column(
                children: [
                  if (title != null) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: CaleeSpacing.md,
                        vertical: CaleeSpacing.sm,
                      ),
                      child: Text(
                        title!,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: CaleeColors.textSecondary,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const Divider(),
                  ],
                  for (int i = 0; i < actions.length; i++) ...[
                    if (i > 0) const Divider(),
                    _ActionRow(actions[i]),
                  ],
                ],
              ),
            ),
            const SizedBox(height: CaleeSpacing.sm),
            Container(
              decoration: BoxDecoration(
                color: CaleeColors.surface,
                borderRadius: BorderRadius.circular(CaleeRadius.card),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(CaleeRadius.card),
                onTap: () => Navigator.of(context).pop(),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: CaleeSpacing.sm + 4,
                  ),
                  child: Center(
                    child: Text(
                      'Cancel',
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: CaleeColors.primary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow(this.action);

  final CaleeAction action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = action.isDestructive
        ? CaleeColors.destructive
        : CaleeColors.textPrimary;

    return InkWell(
      onTap: () {
        Navigator.of(context).pop();
        action.onTap();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: CaleeSpacing.md,
          vertical: CaleeSpacing.sm + 4,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (action.icon != null) ...[
              Icon(action.icon, color: color, size: 20),
              const SizedBox(width: CaleeSpacing.sm),
            ],
            Text(
              action.label,
              style: theme.textTheme.bodyLarge?.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// CaleeDestructiveDialog
// ─────────────────────────────────────────────

/// A confirmation dialog for destructive actions (delete, remove, etc.).
/// Returns [true] if the user confirmed, [false] or [null] otherwise.
class CaleeDestructiveDialog extends StatelessWidget {
  const CaleeDestructiveDialog({
    required this.title,
    required this.body,
    required this.confirmLabel,
    this.cancelLabel = 'Cancel',
    super.key,
  });

  final String title;
  final String body;
  final String confirmLabel;
  final String cancelLabel;

  static Future<bool> show({
    required BuildContext context,
    required String title,
    required String body,
    String confirmLabel = 'Delete',
    String cancelLabel = 'Cancel',
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => CaleeDestructiveDialog(
        title: title,
        body: body,
        confirmLabel: confirmLabel,
        cancelLabel: cancelLabel,
      ),
    );
    return result == true;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(cancelLabel),
        ),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: CaleeColors.destructive),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(
            confirmLabel,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────
// CaleeEmptyState
// ─────────────────────────────────────────────

/// Full-page centred empty state with icon, title, body and optional action.
class CaleeEmptyState extends StatelessWidget {
  const CaleeEmptyState({
    required this.icon,
    required this.title,
    required this.body,
    this.action,
    super.key,
  });

  final IconData icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(CaleeSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: CaleeColors.textTertiary),
            const SizedBox(height: CaleeSpacing.md),
            Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                color: CaleeColors.textPrimary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: CaleeSpacing.xs),
            Text(
              body,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: CaleeColors.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
            if (action != null) ...[
              const SizedBox(height: CaleeSpacing.lg),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// CaleeColorDot
// ─────────────────────────────────────────────

/// A small filled circle used to represent a calendar or list colour.
class CaleeColorDot extends StatelessWidget {
  const CaleeColorDot({required this.color, this.size = 10, super.key});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

// ─────────────────────────────────────────────
// CaleeCheckCircle
// ─────────────────────────────────────────────

/// A tappable check/uncheck circle for task completion, similar to Apple
/// Reminders. Shows a spinner while [isLoading] is true.
class CaleeCheckCircle extends StatelessWidget {
  const CaleeCheckCircle({
    required this.isChecked,
    this.onTap,
    this.isLoading = false,
    this.color,
    this.size = 24,
    super.key,
  });

  final bool isChecked;
  final VoidCallback? onTap;
  final bool isLoading;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final effectiveColor = color ?? Theme.of(context).colorScheme.primary;

    if (isLoading) {
      return GestureDetector(
        onTap: () {},
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: size,
          height: size,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: effectiveColor,
          ),
        ),
      );
    }

    final icon = isChecked
        ? Icon(
            Icons.check_circle,
            size: size,
            color: onTap != null ? effectiveColor : CaleeColors.textTertiary,
          )
        : Icon(
            Icons.radio_button_unchecked,
            size: size,
            color: CaleeColors.textTertiary,
          );

    if (onTap == null) {
      return SizedBox(width: size, height: size, child: icon);
    }

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(width: size, height: size, child: icon),
    );
  }
}

// ─────────────────────────────────────────────
// caleeSectionFieldDecoration
// ─────────────────────────────────────────────

/// Borderless [InputDecoration] for [TextField]s inside a [CaleeSection].
/// Use with `.copyWith(hintText: ...)` to set a hint.
const caleeSectionFieldDecoration = InputDecoration(
  border: InputBorder.none,
  enabledBorder: InputBorder.none,
  focusedBorder: InputBorder.none,
  errorBorder: InputBorder.none,
  focusedErrorBorder: InputBorder.none,
  fillColor: Colors.transparent,
  filled: false,
  contentPadding: EdgeInsets.symmetric(vertical: 9),
);

// ─────────────────────────────────────────────
// CaleeSectionSwitchRow
// ─────────────────────────────────────────────

/// A labelled switch row for use inside a [CaleeSection].
/// Shows [label] on the left and a [Switch] on the right.
/// Pass [enabled] = false to disable the switch.
class CaleeSectionSwitchRow extends StatelessWidget {
  const CaleeSectionSwitchRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: CaleeSpacing.md,
        vertical: 6,
      ),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 16,
              color: enabled
                  ? CaleeColors.textPrimary
                  : CaleeColors.textTertiary,
            ),
          ),
          const Spacer(),
          Switch(value: value, onChanged: enabled ? onChanged : null),
        ],
      ),
    );
  }
}

// CaleeSectionPickerRow
// ─────────────────────────────────────────────

/// A tappable picker row for use inside a [CaleeSection].
/// Shows [label] on the left, [value] on the right, and a chevron.
class CaleeSectionPickerRow extends StatelessWidget {
  const CaleeSectionPickerRow({
    required this.label,
    required this.value,
    this.onTap,
    this.enabled = true,
    super.key,
  });

  final String label;
  final String value;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: CaleeSpacing.md,
          vertical: 11,
        ),
        child: Row(
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 16,
                color: enabled
                    ? CaleeColors.textPrimary
                    : CaleeColors.textTertiary,
              ),
            ),
            const Spacer(),
            Text(
              value,
              style: TextStyle(
                fontSize: 16,
                color: enabled
                    ? CaleeColors.textSecondary
                    : CaleeColors.textTertiary,
              ),
            ),
            const SizedBox(width: CaleeSpacing.xs),
            const Icon(
              Icons.chevron_right,
              size: 20,
              color: CaleeColors.textTertiary,
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// CaleeSectionDropdownRow
// ─────────────────────────────────────────────

/// A labelled dropdown row for use inside a [CaleeSection].
/// Shows [label] on the left, a [DropdownButton] on the right, no underline,
/// and a chevron-right icon. Pass [enabled] = false to disable interaction.
class CaleeSectionDropdownRow<T> extends StatelessWidget {
  const CaleeSectionDropdownRow({
    super.key,
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
    this.enabled = true,
  });

  final String label;
  final T? value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: CaleeSpacing.rowHeight),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          CaleeSpacing.md,
          0,
          CaleeSpacing.sm,
          0,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 16,
                  color: enabled
                      ? CaleeColors.textPrimary
                      : CaleeColors.textTertiary,
                ),
              ),
            ),
            const SizedBox(width: CaleeSpacing.sm),
            Expanded(
              child: DropdownButton<T>(
                value: value,
                isExpanded: true,
                underline: const SizedBox.shrink(),
                icon: const Icon(
                  Icons.chevron_right,
                  size: 20,
                  color: CaleeColors.textTertiary,
                ),
                style: TextStyle(
                  fontSize: 16,
                  color: enabled
                      ? CaleeColors.textSecondary
                      : CaleeColors.textTertiary,
                ),
                selectedItemBuilder: (context) => items
                    .map(
                      (item) => Align(
                        alignment: Alignment.centerRight,
                        child: DefaultTextStyle.merge(
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.right,
                          child: item.child,
                        ),
                      ),
                    )
                    .toList(),
                items: items,
                onChanged: enabled ? onChanged : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// CaleeSectionTextFormField
// ─────────────────────────────────────────────

/// A [TextFormField] row for use inside a [CaleeSection].
/// Applies standard section padding and the borderless
/// [caleeSectionFieldDecoration]. Supports validation, autofocus,
/// multi-line, and keyboard/alignment overrides.
class CaleeSectionTextFormField extends StatelessWidget {
  const CaleeSectionTextFormField({
    super.key,
    required this.controller,
    this.hintText,
    this.enabled = true,
    this.autofocus = false,
    this.textInputAction,
    this.keyboardType,
    this.textAlign = TextAlign.start,
    this.minLines,
    this.maxLines = 1,
    this.validator,
    this.style,
  });

  final TextEditingController controller;
  final String? hintText;
  final bool enabled;
  final bool autofocus;
  final TextInputAction? textInputAction;
  final TextInputType? keyboardType;
  final TextAlign textAlign;
  final int? minLines;
  final int? maxLines;
  final FormFieldValidator<String>? validator;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: CaleeSpacing.md,
        vertical: 2,
      ),
      child: TextFormField(
        controller: controller,
        enabled: enabled,
        autofocus: autofocus,
        textInputAction: textInputAction,
        keyboardType: keyboardType,
        textAlign: textAlign,
        minLines: minLines,
        maxLines: maxLines,
        validator: validator,
        style:
            style ??
            const TextStyle(fontSize: 16, color: CaleeColors.textPrimary),
        decoration: caleeSectionFieldDecoration.copyWith(hintText: hintText),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// CaleeSectionLabeledTextFormField
// ─────────────────────────────────────────────

/// A left-label / right-field row for use inside a [CaleeSection].
/// Shows [label] on the left and a [TextFormField] on the right.
/// Applies standard section padding and the borderless
/// [caleeSectionFieldDecoration]. Supports validation, keyboard type,
/// and text alignment overrides.
class CaleeSectionLabeledTextFormField extends StatelessWidget {
  const CaleeSectionLabeledTextFormField({
    super.key,
    required this.label,
    required this.controller,
    this.hintText,
    this.enabled = true,
    this.keyboardType,
    this.textAlign = TextAlign.right,
    this.validator,
    this.style,
    this.fieldWidth,
  });

  final String label;
  final TextEditingController controller;
  final String? hintText;
  final bool enabled;
  final TextInputType? keyboardType;
  final TextAlign textAlign;
  final FormFieldValidator<String>? validator;
  final TextStyle? style;
  final double? fieldWidth;

  @override
  Widget build(BuildContext context) {
    final field = TextFormField(
      controller: controller,
      enabled: enabled,
      keyboardType: keyboardType,
      textAlign: textAlign,
      validator: validator,
      style:
          style ??
          const TextStyle(fontSize: 16, color: CaleeColors.textSecondary),
      decoration: caleeSectionFieldDecoration.copyWith(hintText: hintText),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: CaleeSpacing.md,
        vertical: 2,
      ),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 16,
              color: enabled
                  ? CaleeColors.textPrimary
                  : CaleeColors.textTertiary,
            ),
          ),
          if (fieldWidth != null)
            SizedBox(width: fieldWidth, child: field)
          else
            Expanded(child: field),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
// CaleeDateHeader
// ─────────────────────────────────────────────

/// A lightweight date heading row (e.g. "Today", "Monday 2 June").
/// Appears above a group of items that share the same date.
class CaleeDateHeader extends StatelessWidget {
  const CaleeDateHeader({required this.label, this.isToday = false, super.key});

  final String label;
  final bool isToday;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = isToday ? CaleeColors.primary : CaleeColors.textSecondary;

    return Padding(
      padding: const EdgeInsets.only(
        top: CaleeSpacing.md,
        bottom: CaleeSpacing.xs,
      ),
      child: Text(
        label,
        style: theme.textTheme.labelLarge?.copyWith(
          color: color,
          fontWeight: isToday ? FontWeight.w700 : FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}
