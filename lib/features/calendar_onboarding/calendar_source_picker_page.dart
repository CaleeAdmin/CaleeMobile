import 'package:flutter/material.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_bootstrap.dart';
import '../../ui/calee_design.dart';
import 'provider_guides/apple_icloud_calendar_guide_page.dart';
import 'provider_guides/generic_calendar_link_page.dart';
import 'provider_guides/google_calendar_guide_page.dart';
import 'provider_guides/outlook_calendar_guide_page.dart';

class CalendarSourcePickerPage extends StatelessWidget {
  const CalendarSourcePickerPage({
    required this.hubClient,
    required this.accessToken,
    required this.services,
    required this.accountId,
    required this.onDone,
    super.key,
  });

  final CaleeHubClient hubClient;
  final String accessToken;
  final List<ClientService> services;
  final String accountId;
  final VoidCallback onDone;

  void _push(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return CaleeScaffold(
      appBar: AppBar(title: const Text('Where is your calendar?')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          CaleeSpacing.pagePadding,
          CaleeSpacing.md,
          CaleeSpacing.pagePadding,
          96,
        ),
        children: [
          Text(
            'Choose the service where your calendar lives.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: CaleeColors.textSecondary,
            ),
          ),
          const SizedBox(height: CaleeSpacing.sectionSpacing),
          CaleeSection(
            children: [
              CaleeListRow(
                title: 'Google Calendar',
                leading: const Icon(
                  Icons.calendar_today_outlined,
                  size: 20,
                  color: CaleeColors.primary,
                ),
                onTap: () => _push(
                  context,
                  GoogleCalendarGuidePage(
                    hubClient: hubClient,
                    accessToken: accessToken,
                    services: services,
                    accountId: accountId,
                    onDone: onDone,
                  ),
                ),
              ),
              CaleeListRow(
                title: 'Apple / iCloud Calendar',
                leading: const Icon(
                  Icons.phone_iphone_outlined,
                  size: 20,
                  color: CaleeColors.primary,
                ),
                onTap: () => _push(
                  context,
                  AppleIcloudCalendarGuidePage(
                    hubClient: hubClient,
                    accessToken: accessToken,
                    services: services,
                    accountId: accountId,
                    onDone: onDone,
                  ),
                ),
              ),
              CaleeListRow(
                title: 'Outlook Calendar',
                leading: const Icon(
                  Icons.mail_outline_rounded,
                  size: 20,
                  color: CaleeColors.primary,
                ),
                onTap: () => _push(
                  context,
                  OutlookCalendarGuidePage(
                    hubClient: hubClient,
                    accessToken: accessToken,
                    services: services,
                    accountId: accountId,
                    onDone: onDone,
                  ),
                ),
              ),
              CaleeListRow(
                title: 'I already have a calendar link',
                leading: const Icon(
                  Icons.link_rounded,
                  size: 20,
                  color: CaleeColors.primary,
                ),
                onTap: () => _push(
                  context,
                  GenericCalendarLinkPage(
                    hubClient: hubClient,
                    accessToken: accessToken,
                    services: services,
                    accountId: accountId,
                    onDone: onDone,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
