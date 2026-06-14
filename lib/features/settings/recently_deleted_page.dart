import 'package:flutter/material.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_deleted_items.dart';
import '../../ui/calee_theme.dart';
import '../../ui/calee_widgets.dart';

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
        _individualItems =
            response.items.where((i) => !i.isListType).toList();
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
          return 'This service does not support restore from Calee yet.';
        case 'DELETED_ITEM_NOT_FOUND':
          return 'This item no longer exists.';
        case 'RESTORE_CONFLICT':
          return 'This item could not be restored because a conflict was'
              ' detected.';
        case 'UPSTREAM_ERROR':
          return 'The connected service returned an error. Please try again.';
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Restored')),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_errorMessage(e, 'Unable to restore item.')),
        ),
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Deleted permanently')),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_errorMessage(e, 'Unable to delete item.')),
        ),
      );
    }
  }

  void _openItemActions(DeletedItem item) {
    CaleeActionSheet.show(
      context: context,
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
    final subtitleParts = [
      _typeLabel(item.type),
      if (item.subtitle != null && item.subtitle!.isNotEmpty) item.subtitle!,
    ];
    final hasActions = item.canRestore || item.canDeletePermanently;

    return CaleeListRow(
      title: item.title,
      subtitle: subtitleParts.join(' · '),
      trailing: hasActions
          ? GestureDetector(
              onTap: () => _openItemActions(item),
              child: const Icon(
                Icons.more_horiz_rounded,
                color: CaleeColors.textTertiary,
                size: 22,
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
        action: TextButton(
          onPressed: _load,
          child: const Text('Try again'),
        ),
      );
    }

    final hasContent = _listItems.isNotEmpty ||
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
              children: [
                for (final item in _listItems) _buildItemRow(item),
              ],
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
                        'Restore is not available for this service yet.',
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
