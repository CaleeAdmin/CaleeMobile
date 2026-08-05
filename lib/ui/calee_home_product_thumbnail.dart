import 'package:flutter/material.dart';

import 'calee_theme.dart';

/// Compact rendering of the approved Calee-for-home product visual — the
/// white-framed Calee tablet (sourced from the approved
/// `product-kitchen-display` website asset).
///
/// Purely decorative: it is excluded from semantics, and if the asset cannot
/// be decoded it falls back to a display icon so promotional rows never
/// break.
class CaleeHomeProductThumbnail extends StatelessWidget {
  const CaleeHomeProductThumbnail({this.size = 48, super.key});

  /// Logical width/height of the square thumbnail.
  final double size;

  static const String assetPath = 'assets/images/calee_home_white_tablet.jpg';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(CaleeRadius.card),
        child: Image.asset(
          assetPath,
          key: const Key('calee_home_product_thumbnail'),
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (context, _, _) => SizedBox(
            width: size,
            height: size,
            child: Icon(
              Icons.tablet_mac_outlined,
              color: theme.colorScheme.primary,
            ),
          ),
        ),
      ),
    );
  }
}
