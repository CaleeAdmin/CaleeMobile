import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../data/api/calee_hub_client.dart';
import '../../../data/models/client_calendar.dart';
import '../../../ui/calee_design.dart';
import 'calendar_widget_helpers.dart';

const List<(String, Color)> _kDetailColorPalette = [
  ('#FF3B30', CaleeColors.dotRed),
  ('#FF9500', CaleeColors.dotOrange),
  ('#FFCC00', CaleeColors.dotYellow),
  ('#34C759', CaleeColors.dotGreen),
  ('#5AC8FA', CaleeColors.dotTeal),
  ('#007AFF', CaleeColors.dotBlue),
  ('#AF52DE', CaleeColors.dotPurple),
  ('#FF2D55', CaleeColors.dotPink),
  ('#8E8E93', CaleeColors.dotGray),
];

enum _DetailMode { info, edit }

class CalendarDetailSheet extends StatefulWidget {
  const CalendarDetailSheet({
    required this.calendar,
    required this.color,
    required this.hubClient,
    required this.accessToken,
    required this.initiallyVisible,
    required this.onToggleAndClose,
    required this.onMutated,
    super.key,
  });

  final ClientCalendar calendar;
  final Color color;
  final CaleeHubClient hubClient;
  final String accessToken;
  final bool initiallyVisible;
  final VoidCallback onToggleAndClose;
  final void Function(String? message) onMutated;

  @override
  State<CalendarDetailSheet> createState() => _CalendarDetailSheetState();
}

class _CalendarDetailSheetState extends State<CalendarDetailSheet> {
  _DetailMode _mode = _DetailMode.info;
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameController;
  late TextEditingController _colorController;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.calendar.name);
    _colorController = TextEditingController(text: widget.calendar.color ?? '');
    _colorController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _nameController.dispose();
    _colorController.dispose();
    super.dispose();
  }

  bool get _canEdit => widget.calendar.capabilities.canEditAppearance;

  bool get _canDelete =>
      !widget.calendar.readOnly || widget.calendar.isSubscription;

  /// Explanatory copy shown in the edit view for the calendar's
  /// appearanceMode, e.g. clarifying that editing a subscription only
  /// changes how it appears in Calee rather than the original calendar.
  String? get _appearanceEditCopy =>
      calendarAppearanceEditCopy(widget.calendar.appearanceMode);

  /// Preserves the provider/source's own name for this calendar somewhere
  /// visible, whenever it differs from the effective name shown/edited here.
  String? get _sourceNameCaption {
    final sourceName = widget.calendar.sourceName?.trim() ?? '';
    if (sourceName.isEmpty || sourceName == widget.calendar.name) return null;
    return 'Originally "$sourceName" at the source.';
  }

  bool _isPaletteSelected(String hex) =>
      _colorController.text.trim().toUpperCase() == hex.toUpperCase();

  Color get _previewColor {
    final hex = _colorController.text.trim();
    if (hex.isEmpty) return widget.color;
    return parseCalendarHexColor(hex) ?? widget.color;
  }

  Future<void> _submitEdit() async {
    if (_isSubmitting || !_formKey.currentState!.validate()) return;
    setState(() => _isSubmitting = true);
    try {
      await widget.hubClient.updateCalendarAppearance(
        accessToken: widget.accessToken,
        calendarId: widget.calendar.id,
        name: _nameController.text.trim(),
        color: _colorController.text.trim().isEmpty
            ? null
            : _colorController.text.trim(),
      );
      if (mounted) widget.onMutated('Calendar updated.');
    } catch (error) {
      if (mounted) {
        setState(() => _isSubmitting = false);
        const friendly = 'Unable to update calendar.';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              kDebugMode && error is CaleeHubException
                  ? '$friendly\nDebug: ${error.debugSummary}'
                  : friendly,
            ),
          ),
        );
      }
    }
  }

  Future<void> _confirmDelete() async {
    final cal = widget.calendar;
    final isSubscription = cal.isSubscription;

    final title = isSubscription
        ? 'Remove connected calendar?'
        : 'Delete Calendar?';
    final body = isSubscription
        ? 'This will remove the connected calendar from Calee. '
              'It will not delete events from the original calendar provider.'
        : 'Delete "${cal.name}" and its events from Calee? '
              'This cannot be undone.';
    final confirmLabel = isSubscription
        ? 'Remove connected calendar'
        : 'Delete Calendar';

    final confirmed = await CaleeDestructiveDialog.show(
      context: context,
      title: title,
      body: body,
      confirmLabel: confirmLabel,
    );
    if (!confirmed || !mounted) return;

    setState(() => _isSubmitting = true);
    try {
      await widget.hubClient.deleteCalendar(
        accessToken: widget.accessToken,
        calendarId: cal.id,
        confirmDeleteItems: true,
      );
      if (mounted) {
        widget.onMutated(
          isSubscription ? 'Calendar link removed.' : 'Calendar deleted.',
        );
      }
    } catch (error) {
      if (mounted) {
        setState(() => _isSubmitting = false);
        const friendly = 'Unable to remove calendar.';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              kDebugMode && error is CaleeHubException
                  ? '$friendly\nDebug: ${error.debugSummary}'
                  : friendly,
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final maxHeight = MediaQuery.of(context).size.height * 0.9;

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: SafeArea(
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
              Flexible(
                child: _mode == _DetailMode.info
                    ? _buildInfoMode()
                    : _buildEditMode(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInfoMode() {
    final cal = widget.calendar;
    final host = calendarSubscriptionHost(cal.subscriptionUrl);
    final theme = Theme.of(context);

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header: color dot + calendar name + close button
          Row(
            children: [
              Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: widget.color,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: CaleeSpacing.sm),
              Expanded(
                child: Text(
                  cal.name,
                  style: theme.textTheme.titleLarge,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).maybePop(),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
          const SizedBox(height: CaleeSpacing.md),

          // Info section
          CaleeSection(
            children: [
              if (cal.serviceName.trim().isNotEmpty)
                _DetailInfoRow(label: 'Account', value: cal.serviceName.trim()),
              _DetailInfoRow(
                label: 'Visibility',
                value: widget.initiallyVisible ? 'Shown' : 'Hidden',
              ),
              if (cal.isSubscription)
                const _DetailInfoRow(
                  label: 'Type',
                  value: 'Connected calendar',
                ),
              if (cal.readOnly)
                const _DetailInfoRow(label: 'Access', value: 'Read-only'),
              // Show source host only — never the full URL (may contain tokens)
              if (host != null) _DetailInfoRow(label: 'Source', value: host),
            ],
          ),
          const SizedBox(height: CaleeSpacing.sectionSpacing),

          // Actions section
          CaleeSection(
            children: [
              _DetailActionRow(
                icon: widget.initiallyVisible
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                title: widget.initiallyVisible
                    ? 'Hide Calendar'
                    : 'Show Calendar',
                onTap: _isSubmitting ? null : widget.onToggleAndClose,
              ),
              if (_canEdit)
                _DetailActionRow(
                  icon: Icons.edit_outlined,
                  title: 'Edit Name & Colour',
                  onTap: _isSubmitting
                      ? null
                      : () => setState(() => _mode = _DetailMode.edit),
                )
              else if (cal.appearanceMode == 'unsupported')
                _DetailInfoNote(
                  icon: Icons.lock_outline,
                  message: calendarOwnerManagedMessage,
                ),
              if (_canDelete)
                _DetailActionRow(
                  icon: cal.isSubscription
                      ? Icons.link_off
                      : Icons.delete_outline,
                  title: cal.isSubscription
                      ? 'Remove connected calendar'
                      : 'Delete Calendar',
                  isDestructive: true,
                  trailing: _isSubmitting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : null,
                  onTap: _isSubmitting ? null : _confirmDelete,
                ),
            ],
          ),
          const SizedBox(height: CaleeSpacing.md),
        ],
      ),
    );
  }

  Widget _buildEditMode() {
    final theme = Theme.of(context);

    return Form(
      key: _formKey,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header with back button
            Row(
              children: [
                GestureDetector(
                  onTap: _isSubmitting
                      ? null
                      : () => setState(() => _mode = _DetailMode.info),
                  child: const Icon(
                    Icons.arrow_back_ios,
                    size: 20,
                    color: CaleeColors.primary,
                  ),
                ),
                const SizedBox(width: CaleeSpacing.sm),
                Text('Edit Calendar', style: theme.textTheme.titleLarge),
              ],
            ),
            const SizedBox(height: CaleeSpacing.sm),

            if (_appearanceEditCopy != null) ...[
              Text(
                _appearanceEditCopy!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: CaleeColors.textSecondary,
                ),
              ),
              const SizedBox(height: CaleeSpacing.xs),
            ],
            if (_sourceNameCaption != null) ...[
              Text(
                _sourceNameCaption!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: CaleeColors.textTertiary,
                ),
              ),
              const SizedBox(height: CaleeSpacing.xs),
            ],
            const SizedBox(height: CaleeSpacing.sm),

            // Color preview dot + name field
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: _previewColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: CaleeSpacing.sm),
                Expanded(
                  child: TextFormField(
                    controller: _nameController,
                    enabled: !_isSubmitting,
                    autofocus: true,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'Name in Calee',
                    ),
                    validator: (value) =>
                        (value ?? '').trim().isEmpty ? 'Enter a name' : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: CaleeSpacing.md),

            Text(
              'Color',
              style: theme.textTheme.bodySmall?.copyWith(
                color: CaleeColors.textSecondary,
              ),
            ),
            const SizedBox(height: CaleeSpacing.sm),

            Wrap(
              spacing: CaleeSpacing.sm,
              runSpacing: CaleeSpacing.sm,
              children: [
                for (final (hex, color) in _kDetailColorPalette)
                  _DetailColorSwatch(
                    hex: hex,
                    color: color,
                    isSelected: _isPaletteSelected(hex),
                    onTap: () => setState(() => _colorController.text = hex),
                  ),
              ],
            ),
            const SizedBox(height: CaleeSpacing.sm + 4),

            TextFormField(
              controller: _colorController,
              enabled: !_isSubmitting,
              decoration: const InputDecoration(
                labelText: 'Colour in Calee',
                hintText: '#007AFF',
              ),
              validator: (value) {
                final c = (value ?? '').trim();
                if (c.isEmpty) return null;
                final norm = c.startsWith('#') ? c : '#$c';
                if (!RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(norm)) {
                  return 'Use a color like #007AFF';
                }
                return null;
              },
            ),
            const SizedBox(height: CaleeSpacing.md),

            FilledButton(
              onPressed: _isSubmitting ? null : _submitEdit,
              child: _isSubmitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailInfoRow extends StatelessWidget {
  const _DetailInfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: CaleeSpacing.md,
        vertical: 11,
      ),
      child: Row(
        children: [
          Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: CaleeColors.textSecondary,
            ),
          ),
          const Spacer(),
          Flexible(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: CaleeColors.textPrimary,
              ),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailActionRow extends StatelessWidget {
  const _DetailActionRow({
    required this.icon,
    required this.title,
    this.isDestructive = false,
    this.onTap,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final bool isDestructive;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final textColor = isDestructive
        ? CaleeColors.destructive
        : CaleeColors.textPrimary;
    final iconColor = isDestructive
        ? CaleeColors.destructive
        : CaleeColors.primary;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: CaleeSpacing.md,
          vertical: 13,
        ),
        child: Row(
          children: [
            Icon(icon, color: iconColor, size: 22),
            const SizedBox(width: CaleeSpacing.md),
            Expanded(
              child: Text(
                title,
                style: TextStyle(fontSize: 16, color: textColor),
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}

/// A non-interactive counterpart to [_DetailActionRow], used to explain why
/// an action (e.g. editing appearance) isn't offered for this calendar.
class _DetailInfoNote extends StatelessWidget {
  const _DetailInfoNote({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: CaleeSpacing.md,
        vertical: 13,
      ),
      child: Row(
        children: [
          Icon(icon, color: CaleeColors.textTertiary, size: 22),
          const SizedBox(width: CaleeSpacing.md),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                fontSize: 14,
                color: CaleeColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailColorSwatch extends StatelessWidget {
  const _DetailColorSwatch({
    required this.hex,
    required this.color,
    required this.isSelected,
    required this.onTap,
  });

  final String hex;
  final Color color;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          border: isSelected
              ? Border.all(
                  color: CaleeColors.textPrimary,
                  width: 2,
                  strokeAlign: BorderSide.strokeAlignOutside,
                )
              : null,
        ),
        child: isSelected
            ? const Icon(Icons.check, size: 16, color: Colors.white)
            : null,
      ),
    );
  }
}
