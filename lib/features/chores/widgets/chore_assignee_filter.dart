import 'package:flutter/material.dart';

import '../../../data/models/client_person.dart';
import '../../../ui/calee_theme.dart';
import '../../../ui/calee_widgets.dart';

class ChoreAssigneeFilterChooser extends StatelessWidget {
  const ChoreAssigneeFilterChooser({
    required this.people,
    required this.hasUnassigned,
    required this.selectedFilter,
    required this.allCount,
    required this.unassignedCount,
    required this.personCounts,
    required this.onSelect,
    this.onAddPerson,
    this.onAddChoreList,
    super.key,
  });

  final List<ClientPerson> people;
  final bool hasUnassigned;
  final String selectedFilter;
  final int allCount;
  final int unassignedCount;
  final Map<String, int> personCounts;
  final ValueChanged<String> onSelect;
  final VoidCallback? onAddPerson;
  final VoidCallback? onAddChoreList;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final countStyle = theme.textTheme.bodySmall?.copyWith(
      color: CaleeColors.textSecondary,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CaleeSection(
          children: [
            CaleeListRow(
              title: 'All chores',
              leading: selectedFilter == 'all'
                  ? const Icon(
                      Icons.check,
                      size: 20,
                      color: CaleeColors.primary,
                    )
                  : const SizedBox(width: 20),
              trailing: Text('$allCount', style: countStyle),
              onTap: () => onSelect('all'),
            ),
            if (hasUnassigned)
              CaleeListRow(
                title: 'For everyone',
                leading: selectedFilter == 'unassigned'
                    ? const Icon(
                        Icons.check,
                        size: 20,
                        color: CaleeColors.primary,
                      )
                    : const SizedBox(width: 20),
                trailing: Text('$unassignedCount', style: countStyle),
                onTap: () => onSelect('unassigned'),
              ),
            for (final person in people)
              CaleeListRow(
                title: person.displayName.trim().isEmpty
                    ? 'Unnamed'
                    : person.displayName.trim(),
                leading: selectedFilter == 'person:${person.id}'
                    ? const Icon(
                        Icons.check,
                        size: 20,
                        color: CaleeColors.primary,
                      )
                    : const SizedBox(width: 20),
                trailing: Text(
                  '${personCounts[person.id] ?? 0}',
                  style: countStyle,
                ),
                onTap: () => onSelect('person:${person.id}'),
              ),
          ],
        ),
        const SizedBox(height: CaleeSpacing.md),
        CaleeSection(
          title: 'Add',
          children: [
            CaleeListRow(
              title: 'Add person',
              leading: const Icon(
                Icons.person_add_outlined,
                color: CaleeColors.primary,
                size: 22,
              ),
              onTap: onAddPerson,
            ),
            CaleeListRow(
              title: 'New chore list',
              leading: const Icon(
                Icons.playlist_add_outlined,
                color: CaleeColors.primary,
                size: 22,
              ),
              onTap: onAddChoreList,
            ),
          ],
        ),
        const SizedBox(height: CaleeSpacing.md),
      ],
    );
  }
}
