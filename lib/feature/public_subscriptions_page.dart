import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/CalendarPageController.dart';
import '../controllers/public_subscriptions_controller.dart';
import '../entity/public_subscription.dart';

class PublicSubscriptionsGetxPage extends StatelessWidget {
  const PublicSubscriptionsGetxPage({super.key});

  @override
  Widget build(BuildContext context) {
    final ctrl = Get.put(PublicSubscriptionsController());
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
              child: Text('Failed to load subscriptions: ${ctrl.error.value}'),
            ),
          );
        }
        final categories = ctrl.categories;
        if (categories.isEmpty) return const Center(child: Text('No public subscriptions found'));
        return ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
          itemCount: categories.length,
          itemBuilder: (context, index) {
            final PublicSubscriptionCategory cat = categories[index];
            return _CategorySection.fromDomain(category: cat);
          },
        );
      }),
    );
  }
}

class _CategorySection extends StatelessWidget {
  final PublicSubscriptionCategory category;
  const _CategorySection({super.key, required this.category});

  factory _CategorySection.fromDomain({required PublicSubscriptionCategory category}) {
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
  final PublicSubscriptionCalendar calendar;
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

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final calendarController = Get.find<CalendarPageController>();
      final isSubscribing = calendarController.subscribingUrls.contains(calendar.icsUrl ?? '');
      final isSubscribed = calendarController.isPublicIcsSubscribed(calendar.icsUrl);
      final shouldDisableSubscribe = calendar.icsUrl == null ||
          calendar.icsUrl?.isEmpty == true ||
          isSubscribing ||
          isSubscribed;

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
                              : Text(
                                  isSubscribed ? 'Subscribed' : 'Subscribe',
                                  style: const TextStyle(fontSize: 13),
                                ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (calendar.description.isNotEmpty)
                      Text(
                        calendar.description,
                        style: _cardBodyStyle,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('By', style: _cardMetaStyle),
                            const SizedBox(height: 4),
                            Text(calendar.ownerUid, style: _cardMetaStyle),
                          ],
                        ),
                        const Spacer(),
                        Row(
                          children: [
                            const Icon(Icons.people, size: 14, color: Color(0xFF9CA3AF)),
                            const SizedBox(width: 6),
                            Text('${calendar.subscribers}', style: _cardMetaStyle),
                          ],
                        ),
                      ],
                    ),
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
