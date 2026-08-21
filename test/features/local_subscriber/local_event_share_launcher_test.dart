// The production share_plus adapter (CaleeAdmin/CaleeMobile#558).
//
// The widget tests prove the PAGE hands the minted URL to a launcher; this
// proves the real launcher hands that same URL to share_plus unchanged, as a
// URI rather than as text somebody could decorate. Without it, changing
// `uri: url` to `text: '$title $url'` would still pass every other suite while
// shipping a link with a title glued to it.
//
// share_plus's own supported testing seam is SharePlatform.instance, so no
// platform channel is touched. `SharePlus.instance` is a lazily-initialised
// `static final` that captures the platform on FIRST access and keeps it for
// the life of the isolate, so exactly one recorder is installed here, once,
// before anything can reach it.

import 'package:calee_mobile/features/local_subscriber/local_event_share_launcher.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:share_plus_platform_interface/share_plus_platform_interface.dart';

class _RecordingSharePlatform extends SharePlatform {
  final List<ShareParams> calls = <ShareParams>[];

  ShareResult result = const ShareResult('ok', ShareResultStatus.success);

  @override
  Future<ShareResult> share(ShareParams params) async {
    calls.add(params);
    return result;
  }
}

const _kLink = 'https://calembed.calee.com.au/e/1.cGF5bG9hZA.c2ln';
const _kOrigin = Rect.fromLTWH(16, 480, 320, 48);

Future<void> _share() => const SharePlusEventShareLauncher().share(
  url: Uri.parse(_kLink),
  title: 'Book club',
  sharePositionOrigin: _kOrigin,
);

void main() {
  final platform = _RecordingSharePlatform();
  SharePlatform.instance = platform;

  setUp(() {
    platform.calls.clear();
    platform.result = const ShareResult('ok', ShareResultStatus.success);
  });

  test('shares the minted link as a URI, byte for byte', () async {
    await _share();

    expect(platform.calls, hasLength(1));
    final params = platform.calls.single;
    expect(params.uri.toString(), _kLink);
    // No title glued on, no date, no utm/source/signedOut parameter — and no
    // text field at all, which is also what keeps `uri` legal in ShareParams.
    expect(params.text, isNull);
    expect(params.files, isNull);
  });

  test(
    'offers the event title only as the sheet heading and subject',
    () async {
      await _share();

      final params = platform.calls.single;
      expect(params.title, 'Book club');
      expect(params.subject, 'Book club');
      // The title never becomes part of the link itself.
      expect(params.uri.toString(), isNot(contains('Book')));
    },
  );

  test('passes the iPad popover anchor through unchanged', () async {
    await _share();

    expect(platform.calls.single.sharePositionOrigin, _kOrigin);
  });

  test('a dismissed share sheet completes normally', () async {
    platform.result = const ShareResult('', ShareResultStatus.dismissed);

    await expectLater(_share(), completes);
    expect(platform.calls, hasLength(1));
  });
}
