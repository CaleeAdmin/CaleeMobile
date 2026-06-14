import 'package:flutter/material.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_deleted_items.dart';
import '../../ui/calee_theme.dart';
import '../../ui/calee_widgets.dart';

String _formatDeletedDate(String iso) {
  try {
    final dt = DateTime.parse(iso).toLocal();
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return 'Deleted ${dt.day} ${months[dt.month - 1]}';
  } catch (_) {
    return '';
  }
}

String? _formatDaysLeft(String iso) {
  try {
    final expires = DateTime.parse(iso).toLocal();
    final now = DateTime.now();
    final days = expires.difference(now).inDays;
    if (days < 0) return null;
    if (days == 0) return 'Expires today';
    return '$days ${days == 1 ? 'day' : 'days'} left';
  } catch (_) {
    return null;
  }
}

String _typeLabel(String type) {
  switch (type) {
    case 'calendar':
      return 'Calendar';
    case 'task_list':
      return 'Task list';
    case 'chore_list':
      return 'Chore list';
    case 'event':
      return 'Event';
    case 'task':
      return 'Task';
    case 'chore':
      return 'Chore';
    default:
      return type;
  }
}

class RecentlyDeletedPage extends StatefulWidget {
  const RecentlyDeletedPage({
    required this.hubClient,
    required this.accessToken,
    super.key,
  });

  final CaleeHubClient hubClient;
  final String accessToken;

  @override
  State<RecentlyDeletedPage> createState() => _RecentlyDeletedPageState();
}

class _RecentlyDeletedPageState extends State<RecentlyDeletedPage> {
  bool _isLoading = true;
  String? _error;
  List<DeletedItem> _listItems = [];
  List<DeletedItem> _individualItems = [];
  List<UnsupportedDeletedItemsService> _unsupportedServices = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final response = await widget.hubClient.listDeletedItems(
        accessToken: widget.accessToken,
      );
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _listItems = response.items.where((i) => i.isListType).toList();
        _individualItems = response.items.where((i) => !i.isListType).toList();
        _unsupportedServices = response.unsupportedServices;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = _errorMessage(e, 'Unable to load recently deleted items.');
      });
    }
  }

  String _errorMessage(Object error, String fallback) {
    if (error is CaleeHubException) {
      switch (error.code) {
        case 'SERVICE_NOT_SUPPORTED':
          return 'Recently deleted is not available for this connected'
              ' service yet.';
        case 'DELETED_ITEM_NOT_FOUND':
          return 'This item is no longer available.';
        case 'RESTORE_CONFLICT':
          return 'Could not restore because another item with the same name'
              ' already exists.';
        case 'UPSTREAM_ERROR':
          return 'Calendar service unavailable. Please try again later.';
        case 'UNAUTHORIZED':
        case 'FORBIDDEN':
          return 'You do not have permission to perform this action.';
      }
      if (error.message.trim().isNotEmpty) return error.message;
    }
    return fallback;
  }

  Future<void> _restore(DeletedItem item) async {
    try {
      await widget.hubClient.restoreDeletedItem(
        accessToken: widget.accessToken,
        serviceId: item.serviceId,
        deletedItemId: item.deletedItemId,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Restored')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_errorMessage(e, 'Unable to restore item.'))),
      );
    }
  }

  Future<void> _deletePermanently(DeletedItem item) async {
    final confirmed = await CaleeDestructiveDialog.show(
      context: context,
      title: 'Delete permanently?',
      body: 'This cannot be undone.',
      confirmLabel: 'Delete permanently',
    );
    if (!confirmed || !mounted) return;

    try {
      await widget.hubClient.deleteDeletedItemPermanently(
        accessToken: widget.accessToken,
        serviceId: item.serviceId,
        deletedItemId: item.deletedItemId,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Deleted permanently')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_errorMessage(e, 'Unable to delete item.'))),
      );
    }
  }

  IconData _leadingIcon(String type) {
    switch (type) {
      case 'event':
        return Icons.event_outlined;
      case 'task':
        return Icons.check_circle_outline;
      case 'chore':
        return Icons.cleaning_services_outlined;
      case 'calendar':
        return Icons.calendar_month_outlined;
      case 'task_list':
        return Icons.checklist_outlined;
      case 'chore_list':
        return Icons.cleaning_services_outlined;
      default:
        return Icons.article_outlined;
    }
  }

  void _openItemActions(DeletedItem item) {
    CaleeActionSheet.show(
      context: context,
      title: item.title,
      actions: [
        if (item.canRestore)
          CaleeAction(
            label: 'Restore',
            icon: Icons.restore_rounded,
            onTap: () => _restore(item),
          ),
        if (item.canDeletePermanently)
          CaleeAction(
            label: 'Delete permanently',
            icon: Icons.delete_forever_outlined,
            isDestructive: true,
            onTap: () => _deletePermanently(item),
          ),
      ],
    );
  }

  Widget _buildItemRow(DeletedItem item) {
    final deletedDateLabel = item.deletedAt.isNotEmpty
        ? _formatDeletedDate(item.deletedAt)
        : '';
    final daysLeftLabel = item.expiresAt != null
        ? _formatDaysLeft(item.expiresAt!)
        : null;
    final subtitleParts = [
      _typeLabel(item.type),
      if (item.subtitle != null && item.subtitle!.isNotEmpty) item.subtitle!,
      if (deletedDateLabel.isNotEmpty) deletedDateLabel,
      if (daysLeftLabel != null) daysLeftLabel,
    ];
    final hasActions = item.canRestore || item.canDeletePermanently;

    return CaleeListRow(
      title: item.title,
      subtitle: subtitleParts.join(' · '),
      leading: Icon(
        _leadingIcon(item.type),
        color: CaleeColors.textTertiary,
        size: 20,
      ),
      trailing: hasActions
          ? Builder(
              builder: (context) => SizedBox(
                width: 28,
                height: 28,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  icon: const Icon(
                    Icons.more_horiz,
                    color: CaleeColors.textTertiary,
                    size: 20,
                  ),
                  onPressed: () => _openItemActions(item),
                ),
              ),
            )
          : const SizedBox.shrink(),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return CaleeEmptyState(
        icon: Icons.error_outline,
        title: 'Unable to load',
        body: _error!,
        action: TextButton(onPressed: _load, child: const Text('Try again')),
      );
    }

    final hasContent =
        _listItems.isNotEmpty ||
        _individualItems.isNotEmpty ||
        _unsupportedServices.isNotEmpty;

    if (!hasContent) {
      return const CaleeEmptyState(
        icon: Icons.restore_from_trash_outlined,
        title: 'Nothing recently deleted',
        body: 'Deleted items will appear here for a limited time.',
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          CaleeSpacing.pagePadding,
          CaleeSpacing.md,
          CaleeSpacing.pagePadding,
          96,
        ),
        children: [
          if (_listItems.isNotEmpty) ...[
            CaleeSection(
              title: 'Calendars and lists',
              children: [for (final item in _listItems) _buildItemRow(item)],
            ),
            const SizedBox(height: CaleeSpacing.sectionSpacing),
          ],
          if (_individualItems.isNotEmpty) ...[
            CaleeSection(
              title: 'Items',
              children: [
                for (final item in _individualItems) _buildItemRow(item),
              ],
            ),
            const SizedBox(height: CaleeSpacing.sectionSpacing),
          ],
          if (_unsupportedServices.isNotEmpty)
            CaleeSection(
              title: 'Unsupported services',
              children: [
                for (final service in _unsupportedServices)
                  CaleeListRow(
                    title: service.displayName,
                    subtitle:
                        service.message ??
                        'Recently deleted is not available for this'
                            ' connected service yet.',
                    trailing: const SizedBox.shrink(),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CaleeScaffold(
      appBar: AppBar(title: const Text('Recently deleted')),
      body: _buildBody(context),
    );
  }
}
