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

  String? _calendarAppStatusLabel() {
    switch (service.calendarCredentialStatus) {
      case 'connected':
        return 'Connected';
      case 'missing':
        return 'Setup needed';
      case 'unsupported':
        return null;
      default:
        final raw = service.calendarCredentialStatus;
        if (raw.isEmpty) return null;
        return raw[0].toUpperCase() + raw.substring(1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final calendarAppStatusLabel = _calendarAppStatusLabel();
    final calendarCredentialMissing = service.hasMissingCalendarCredential;

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
              if (service.supportsCalendarCredential &&
                  calendarAppStatusLabel != null)
                CaleeListRow(
                  title: 'Calendar App Status',
                  trailing: Text(
                    calendarAppStatusLabel,
                    style: const TextStyle(
                      fontSize: 14,
                      color: CaleeColors.textSecondary,
                    ),
                  ),
                ),
              CaleeListRow(
                title: 'Calendar App Setup',
                subtitle: calendarCredentialMissing
                    ? 'Set up the calendar app connection so this service '
                          'can use calendar features.'
                    : null,
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
                subtitle: service.supportsCalendarSharingAddress
                    ? 'Receive shared calendar invitations'
                    : 'Not available for this service',
                enabled: service.supportsCalendarSharingAddress,
                onTap: service.supportsCalendarSharingAddress
                    ? () => _openCalendarSharingAddress(context)
                    : null,
                trailing: service.supportsCalendarSharingAddress
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
