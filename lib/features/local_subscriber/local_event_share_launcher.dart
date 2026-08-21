/// Handing one canonical Event Link to the platform's own share sheet.
///
/// A one-method seam rather than a direct `SharePlus.instance.share(...)` call
/// from the details sheet, for two reasons. Widget tests must be able to prove
/// WHICH URL reached the share sheet without standing up a real platform
/// channel; and the iPad popover anchor has to be computed from the tapped
/// button, which is UI knowledge the plugin call has no business holding.
library;

import 'dart:ui' show Rect;

import 'package:share_plus/share_plus.dart';

/// Opens the OS share sheet for one Event Link.
abstract interface class LocalEventShareLauncher {
  /// Shares [url] EXACTLY as minted.
  ///
  /// The link is never decorated: no title appended to it, no date, no
  /// campaign or source parameter, no `signedOut` flag. Anything added would
  /// change the bytes CalEmbed signed and would follow the recipient around
  /// for as long as they keep the link.
  ///
  /// [title] is the event's own title, offered to the platform as the share
  /// sheet's heading/subject where the OS supports one. It travels no further
  /// than the sheet — it is never sent to CalEmbed.
  ///
  /// [sharePositionOrigin] is the on-screen rect of the control the user
  /// tapped. iPadOS anchors the sheet to it as a popover and rejects the
  /// presentation outright without a valid one, so it is required rather than
  /// optional here.
  Future<void> share({
    required Uri url,
    required String title,
    required Rect sharePositionOrigin,
  });
}

/// Production launcher, on the `share_plus` already pinned by the app.
class SharePlusEventShareLauncher implements LocalEventShareLauncher {
  const SharePlusEventShareLauncher();

  @override
  Future<void> share({
    required Uri url,
    required String title,
    required Rect sharePositionOrigin,
  }) async {
    // `uri` rather than `text`: on iOS it lets the system fetch the page and
    // show a real link preview, and it keeps the link an unmodified URL rather
    // than a string somebody could append to. The two are mutually exclusive
    // in ShareParams, which is exactly the property wanted here.
    await SharePlus.instance.share(
      ShareParams(
        uri: url,
        title: title,
        subject: title,
        sharePositionOrigin: sharePositionOrigin,
      ),
    );
    // A dismissed share sheet is a normal outcome, not a failure: the result
    // is deliberately not inspected or turned into a message.
  }
}
