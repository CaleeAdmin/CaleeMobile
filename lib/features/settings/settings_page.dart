import 'package:flutter/material.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_bootstrap.dart';
import '../../ui/calee_theme.dart';
import '../../ui/calee_widgets.dart';
import 'calendar_collections_page.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    required this.hubClient,
    required this.accessToken,
    required this.bootstrap,
    required this.onSignOut,
    super.key,
  });

  final CaleeHubClient hubClient;
  final String accessToken;
  final ClientBootstrap bootstrap;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final account = bootstrap.account;

    return ListView(
      padding: const EdgeInsets.symmetric(
        horizontal: CaleeSpacing.pagePadding,
        vertical: CaleeSpacing.md,
      ),
      children: [
        // ── Account ──────────────────────────────────
        CaleeSection(
          title: 'Account',
          children: [
            CaleeListRow(
              title: account.displayName ?? 'Calee user',
              subtitle: account.primaryEmail ?? account.id,
              leading: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: CaleeColors.primary.withAlpha(26),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.person_outline,
                  size: 18,
                  color: CaleeColors.primary,
                ),
              ),
            ),
          ],
        ),

        const SizedBox(height: CaleeSpacing.sectionSpacing),

        // ── Manage ───────────────────────────────────
        CaleeSection(
          title: 'Manage',
          children: [
            CaleeListRow(
              title: 'Lists & calendars',
              leading: const Icon(
                Icons.calendar_month_outlined,
                size: 20,
                color: CaleeColors.primary,
              ),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => CalendarCollectionsPage(
                      hubClient: hubClient,
                      accessToken: accessToken,
                      services: bootstrap.services,
                    ),
                  ),
                );
              },
            ),
          ],
        ),

        const SizedBox(height: CaleeSpacing.sectionSpacing),

        // ── Services ─────────────────────────────────
        CaleeSection(
          title: 'Services',
          children: [
            if (bootstrap.services.isEmpty)
              _EmptyRowText('No services connected.')
            else
              for (final service in bootstrap.services)
                _ServiceRow(service: service),
          ],
        ),

        const SizedBox(height: CaleeSpacing.sectionSpacing),

        // ── Contexts ─────────────────────────────────
        CaleeSection(
          title: 'Contexts',
          children: [
            if (bootstrap.availableContexts.isEmpty)
              _EmptyRowText('No household or organisation contexts yet.')
            else
              for (final ctx in bootstrap.availableContexts)
                _ContextRow(context: ctx),
          ],
        ),

        const SizedBox(height: CaleeSpacing.sectionSpacing),

        // ── Sign out ─────────────────────────────────
        CaleeSection(
          children: [
            CaleeListRow(
              title: 'Sign out',
              titleStyle: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: CaleeColors.destructive,
                  ),
              onTap: onSignOut,
              trailing: const SizedBox.shrink(),
            ),
          ],
        ),

        const SizedBox(height: 96),
      ],
    );
  }
}

// ─────────────────────────────────────────────
// _ServiceRow
// ─────────────────────────────────────────────

class _ServiceRow extends StatelessWidget {
  const _ServiceRow({required this.service});

  final ClientService service;

  @override
  Widget build(BuildContext context) {
    final hasMissing = service.hasMissingCalendarCredential;

    final subtitle = '${service.baseUrl} · ${service.accessStatus}';

    return CaleeListRow(
      title: service.displayName,
      subtitle: subtitle,
      leading: Icon(
        Icons.cloud_outlined,
        size: 20,
        color: hasMissing ? CaleeColors.dotOrange : CaleeColors.textTertiary,
      ),
      trailing: hasMissing
          ? const Icon(
              Icons.warning_amber_rounded,
              size: 16,
              color: CaleeColors.dotOrange,
            )
          : const SizedBox.shrink(),
    );
  }
}

// ─────────────────────────────────────────────
// _ContextRow
// ─────────────────────────────────────────────

class _ContextRow extends StatelessWidget {
  const _ContextRow({required this.context});

  final ClientContext context;

  @override
  Widget build(BuildContext context) {
    final typeLabel =
        this.context.type.isNotEmpty ? _capitalise(this.context.type) : null;
    final roleLabel =
        this.context.role.isNotEmpty ? _capitalise(this.context.role) : null;

    final subtitle = [typeLabel, roleLabel].whereType<String>().join(' · ');

    return CaleeListRow(
      title: this.context.name.isNotEmpty ? this.context.name : 'Unnamed',
      subtitle: subtitle.isNotEmpty ? subtitle : null,
      leading: const Icon(
        Icons.group_outlined,
        size: 20,
        color: CaleeColors.textTertiary,
      ),
      trailing: const SizedBox.shrink(),
    );
  }

  String _capitalise(String value) {
    if (value.isEmpty) return value;
    return value[0].toUpperCase() + value.substring(1);
  }
}

// ─────────────────────────────────────────────
// _EmptyRowText
// ─────────────────────────────────────────────

class _EmptyRowText extends StatelessWidget {
  const _EmptyRowText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: CaleeSpacing.md,
        vertical: CaleeSpacing.sm + 4,
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: CaleeColors.textSecondary,
            ),
      ),
    );
  }
}
