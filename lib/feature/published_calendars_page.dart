import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/CalendarPageController.dart';
import '../controllers/published_calendars_controller.dart';
import '../entity/published_calendar.dart';

class PublishedCalendarsGetxPage extends StatelessWidget {
  const PublishedCalendarsGetxPage({super.key});

  @override
  Widget build(BuildContext context) {
    final ctrl = Get.put(PublishedCalendarsController());
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios),
          onPressed: () => Navigator.maybePop(context),
        ),
        title: const Text(
          'Subscribe to Calee Calendar',
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 18),
        ),
        elevation: 0,
      ),
      body: Obx(() {
        if (ctrl.isLoading.value) return const Center(child: CircularProgressIndicator());
        if (ctrl.error.value.isNotEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Failed to load calendars: ${ctrl.error.value}'),
            ),
          );
        }
        final categories = ctrl.categories;
        if (categories.isEmpty) return const Center(child: Text('No Calee calendars found'));
        return ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
          itemCount: categories.length,
          itemBuilder: (context, index) {
            final PublishedCalendarCategory cat = categories[index];
            return _CategorySection.fromDomain(category: cat);
          },
        );
      }),
    );
  }
}

class _CategorySection extends StatelessWidget {
  final PublishedCalendarCategory category;
  const _CategorySection({super.key, required this.category});

  factory _CategorySection.fromDomain({required PublishedCalendarCategory category}) {
    return _CategorySection(category: category);
  }

  static const _titleStyle = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    color: Colors.black87,
  );

  static const _metaStyle = TextStyle(
    fontSize: 12,
    color: Color(0xFF6B7280),
  );

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 18),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(category.title, style: _titleStyle),
          const SizedBox(height: 6),
          Text(
            '${category.calendars.length} calendar${category.calendars.length > 1 ? "s" : ""} available',
            style: _metaStyle,
          ),
          const SizedBox(height: 12),
          Column(
            children: category.calendars
                .map(
                  (c) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _CalendarCard(calendar: c),
                  ),
                )
                .toList(),
          ),
        ],
      ),
    );
  }
}

class _CalendarCard extends StatelessWidget {
  final PublishedCalendar calendar;
  const _CalendarCard({super.key, required this.calendar});

  static const _cardTitleStyle = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w600,
    color: Colors.black87,
  );

  static const _cardBodyStyle = TextStyle(
    fontSize: 14,
    color: Color(0xFF4B5563),
  );

  static const _cardMetaStyle = TextStyle(
    fontSize: 12,
    color: Color(0xFF4B5563),
  );

  static const _publisherPrefixStyle = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w500,
    color: Color(0xFF6B7280),
  );

  static const _publisherNameStyle = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w600,
    color: Color(0xFF374151),
  );

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final calendarController = Get.find<CalendarPageController>();
      final isSubscribing = calendarController.subscribingUrls.contains(calendar.icsUrl ?? '');
      final isSubscribed = calendarController.isPublicIcsSubscribed(calendar.icsUrl);
      final shouldDisableSubscribe = calendar.icsUrl == null ||
          calendar.icsUrl?.isEmpty == true ||
          isSubscribing;

      return Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        elevation: 0,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: calendar.color,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Center(child: Icon(Icons.calendar_today, color: Colors.white)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            calendar.title,
                            style: _cardTitleStyle.copyWith(fontSize: 16),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (isSubscribed)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: const Color(0xFFE8F5E9),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: const Color(0xFFA5D6A7)),
                            ),
                            child: const Text(
                              'Subscribed',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF2E7D32),
                              ),
                            ),
                          )
                        else
                          ElevatedButton(
                            onPressed: shouldDisableSubscribe
                                ? null
                                : () async {
                                    final ok = await calendarController.subscribePublicIcs(calendar.icsUrl!);
                                    if (ok) {
                                      Get.snackbar(
                                        'Subscribed',
                                        'Subscribed to "${calendar.title}"',
                                        snackPosition: SnackPosition.BOTTOM,
                                      );
                                      Navigator.of(context).pop(true);
                                    } else {
                                      Get.snackbar(
                                        'Subscribe failed',
                                        'Failed to subscribe to "${calendar.title}"',
                                        snackPosition: SnackPosition.BOTTOM,
                                        backgroundColor: Colors.red.shade50,
                                      );
                                      Navigator.of(context).pop(false);
                                    }
                                  },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.black87,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                              elevation: 2,
                            ),
                            child: isSubscribing
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                    ),
                                  )
                                : const Text(
                                    'Subscribe',
                                    style: TextStyle(fontSize: 13),
                                  ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text.rich(
                      TextSpan(
                        children: [
                          const TextSpan(
                            text: 'From ',
                            style: _publisherPrefixStyle,
                          ),
                          TextSpan(
                            text: calendar.ownerDisplayName.isNotEmpty
                                ? calendar.ownerDisplayName
                                : calendar.ownerUid,
                            style: _publisherNameStyle,
                          ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (calendar.description.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        calendar.description,
                        style: _cardBodyStyle,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    });
  }
}
