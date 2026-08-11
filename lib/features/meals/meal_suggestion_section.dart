import 'package:flutter/material.dart';

import '../../ui/calee_design.dart';
import 'meal_suggestion_resolver.dart';

class MealSuggestionSection extends StatefulWidget {
  const MealSuggestionSection({
    required this.sectionId,
    required this.title,
    required this.suggestions,
    required this.emptyText,
    required this.itemBuilder,
    this.footer,
    this.pageSize = 3,
    super.key,
  });

  final String sectionId;
  final String title;
  final List<MealSuggestion> suggestions;
  final String emptyText;
  final Widget Function(MealSuggestion suggestion) itemBuilder;
  final String? footer;
  final int pageSize;

  @override
  State<MealSuggestionSection> createState() => _MealSuggestionSectionState();
}

class _MealSuggestionSectionState extends State<MealSuggestionSection> {
  late int _visibleCount;

  @override
  void initState() {
    super.initState();
    _visibleCount = widget.pageSize;
  }

  @override
  void didUpdateWidget(covariant MealSuggestionSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.suggestions, widget.suggestions)) {
      _visibleCount = widget.pageSize;
    }
  }

  void _showMore() {
    setState(() {
      final next = _visibleCount + widget.pageSize;
      _visibleCount = next < widget.suggestions.length
          ? next
          : widget.suggestions.length;
    });
  }

  @override
  Widget build(BuildContext context) {
    final visible = widget.suggestions.take(_visibleCount).toList();
    return CaleeSection(
      key: ValueKey('meal_suggestions_${widget.sectionId}_section'),
      title: widget.title,
      footer: widget.footer,
      children: [
        if (widget.suggestions.isEmpty)
          CaleeListRow(
            title: widget.emptyText,
            titleStyle: const TextStyle(
              fontSize: 14,
              color: CaleeColors.textSecondary,
            ),
          )
        else ...[
          ...visible.map(widget.itemBuilder),
          if (_visibleCount < widget.suggestions.length)
            CaleeListRow(
              key: ValueKey('meal_suggestions_${widget.sectionId}_more'),
              title: 'More',
              trailing: const Icon(
                Icons.expand_more,
                color: CaleeColors.primary,
              ),
              onTap: _showMore,
            ),
        ],
      ],
    );
  }
}
