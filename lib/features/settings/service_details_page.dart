import 'package:flutter/material.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_bootstrap.dart';
import '../../ui/calee_theme.dart';
import '../../ui/calee_widgets.dart';
import 'calendar_app_setup_page.dart';
import 'calendar_sharing_address_page.dart';

class ServiceDetailsPage extends StatelessWidget {
  const ServiceDetailsPage({
    required this.hubClient,
    required this.accessToken,
    required this.service,
    super.key,
  });

  final CaleeHubClient hubClient;
  final String accessToken;
  final ClientService service;

  void _openCalendarSetup(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CalendarAppSetupPage(
          hubClient: hubClient,
          accessToken: accessToken,
          serviceId: service.id,
        ),
      ),
    );
  }

  void _openCalendarSharingAddress(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CalendarSharingAddressPage(
          hubClient: hubClient,
          accessToken: accessToken,
          serviceId: service.id,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CaleeScaffold(
      appBar: AppBar(title: const Text('Service Details')),
      body: ListView(
        padding: const EdgeInsets.symmetric(
          horizontal: CaleeSpacing.pagePadding,
          vertical: CaleeSpacing.md,
        ),
        children: [
          CaleeSection(
            children: [
              CaleeListRow(
                title: service.displayName,
                leading: const Icon(
                  Icons.cloud_outlined,
                  size: 20,
                  color: CaleeColors.primary,
                ),
                trailing: const SizedBox.shrink(),
              ),
              CaleeListRow(
                title: 'Access status',
                trailing: Text(
                  service.accessStatus,
                  style: const TextStyle(
                    fontSize: 14,
                    color: CaleeColors.textSecondary,
                  ),
                ),
              ),
              CaleeListRow(
                title: 'Base URL',
                subtitle: service.baseUrl,
                trailing: const SizedBox.shrink(),
              ),
            ],
          ),
          const SizedBox(height: CaleeSpacing.sectionSpacing),
          CaleeSection(
            title: 'Calendar',
            children: [
              CaleeListRow(
                title: 'Calendar App Setup',
                enabled: service.supportsCalendarCredential,
                onTap: service.supportsCalendarCredential
                    ? () => _openCalendarSetup(context)
                    : null,
                trailing: service.supportsCalendarCredential
                    ? null
                    : const SizedBox.shrink(),
              ),
              CaleeListRow(
                title: 'Calendar Sharing Address',
                subtitle: 'Receive shared calendar invitations',
                enabled: service.supportsCalendarCredential,
                onTap: service.supportsCalendarCredential
                    ? () => _openCalendarSharingAddress(context)
                    : null,
                trailing: service.supportsCalendarCredential
                    ? null
                    : const SizedBox.shrink(),
              ),
            ],
          ),
          const SizedBox(height: 96),
        ],
      ),
    );
  }
}
