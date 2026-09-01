import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/calee_links.dart';

/// Opens one of the canonical Calee legal documents.
///
/// Injectable so a widget test can observe the exact URL a surface offers
/// without touching the url_launcher platform channel, which is how the
/// canonical-URL tests assert the constant rather than re-declaring it.
typedef LegalLinkLauncher = Future<void> Function(String url);

/// Opens [url] in the device's browser.
///
/// Always [LaunchMode.externalApplication]: a legal document belongs in the
/// browser, where the user can see the address it came from, not in an in-app
/// web view that could be mistaken for part of Calee.
Future<void> openCaleeLegalUrl(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// A quiet Terms of Use / Privacy Policy pair.
///
/// Both documents are always offered together. Welcome, Login and Create
/// Account each used to hard-code their own `https://portal.calee.com.au/terms`
/// literal and offer Terms alone -- which is how the app came to point users at
/// an organisation-centric Portal document and never at the Privacy Policy at
/// all. One widget, one pair of constants, every surface.
///
/// This is a link, not an acceptance control. It records nothing, stores
/// nothing and gates nothing.
class CaleeLegalLinks extends StatelessWidget {
  const CaleeLegalLinks({
    this.launcher,
    this.alignment = WrapAlignment.center,
    super.key,
  });

  final LegalLinkLauncher? launcher;
  final WrapAlignment alignment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final launch = launcher ?? openCaleeLegalUrl;
    final style = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.primary,
    );

    Widget link(String label, String url, Key key) => TextButton(
      key: key,
      onPressed: () => launch(url),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        minimumSize: const Size(0, 36),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(label, style: style),
    );

    // Wrap rather than Row: at large accessibility text sizes the two labels
    // no longer fit side by side, and a Row would overflow instead of
    // stacking.
    return Wrap(
      alignment: alignment,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        link('Terms of Use', kCaleeTermsUrl, const Key('legal_terms_link')),
        link(
          'Privacy Policy',
          kCaleePrivacyUrl,
          const Key('legal_privacy_link'),
        ),
      ],
    );
  }
}

/// The legal notice shown on the account-creation screen.
///
/// The sentence states what creating an account means and offers both
/// documents. It deliberately introduces NO acceptance mechanism: no checkbox,
/// no terms version, no accepted-at timestamp, no re-consent prompt and no
/// backend field. Whether Calee must record an accepted Terms version is an
/// open product/legal decision in CaleeAdmin/calee-hub-web#107, and inventing
/// acceptance state here would pre-empt it -- and would create evidence the
/// backend does not actually hold.
class CaleeAccountLegalNotice extends StatelessWidget {
  const CaleeAccountLegalNotice({this.launcher, super.key});

  final LegalLinkLauncher? launcher;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'By creating a Calee account, you agree to the Calee Terms of Use '
          'and acknowledge the Privacy Policy.',
          key: const Key('create_account_legal_notice'),
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        CaleeLegalLinks(launcher: launcher),
      ],
    );
  }
}
