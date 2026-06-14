import 'package:flutter/material.dart';

import '../../ui/calee_theme.dart';
import '../../ui/calee_widgets.dart';

// TODO(displays): Future implementation plan for Calee display linking:
//   1. Existing signed-in CaleeMobile user scans a Calee display QR code.
//   2. App sends the display native-login URL/token to Hub/Core.
//   3. Hub/Core approves the display login using the signed-in mobile account.
//   4. Calee display auto-logins.
//   - Do not pass passwords, app passwords, or long-lived tokens through URLs.
//   - Use short-lived, single-use tokens.

class CaleeDisplaysPage extends StatelessWidget {
  const CaleeDisplaysPage({super.key});

  @override
  Widget build(BuildContext context) {
    return CaleeScaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(
            horizontal: CaleeSpacing.pagePadding,
            vertical: CaleeSpacing.md,
          ),
          children: [
            _buildPageHeader(),
            const SizedBox(height: CaleeSpacing.md),
            CaleeSection(
              children: [
                CaleeListRow(
                  title: 'No Calee displays linked yet.',
                  subtitle:
                      'You will be able to link and check your Calee display here.',
                  titleStyle: const TextStyle(
                    fontSize: 15,
                    color: CaleeColors.textSecondary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: CaleeSpacing.sectionSpacing),
            CaleeSection(
              children: [
                CaleeListRow(
                  title: 'Link a Calee display',
                  subtitle: 'Coming soon',
                  leading: const Icon(
                    Icons.tablet_mac_outlined,
                    size: 20,
                    color: CaleeColors.textTertiary,
                  ),
                  titleStyle: const TextStyle(
                    fontSize: 15,
                    color: CaleeColors.textSecondary,
                  ),
                  subtitleStyle: const TextStyle(
                    fontSize: 13,
                    color: CaleeColors.textTertiary,
                  ),
                  onTap: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Display linking is coming soon.'),
                      ),
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 96),
          ],
        ),
      ),
    );
  }

  Widget _buildPageHeader() {
    return const Padding(
      padding: EdgeInsets.only(bottom: CaleeSpacing.md),
      child: Text(
        'Calee displays',
        style: TextStyle(
          fontSize: 32,
          fontWeight: FontWeight.bold,
          color: CaleeColors.textPrimary,
          height: 1.1,
        ),
      ),
    );
  }
}
