// No production Mobile source may point users at the Portal legal documents
// (CaleeAdmin/calee-hub-web#107).
//
// The widget tests prove that each surface offers the canonical URL today.
// They cannot prove that a NEW surface, added later, does not reintroduce
// `https://portal.calee.com.au/terms` -- which is exactly how three separate
// copies of that literal came to exist in Welcome, Login and Create Account in
// the first place. This scans lib/ instead, so the rule holds for code that
// does not exist yet.
//
// Scoped deliberately: the Portal HOST is still legitimate in Mobile, because
// portal.calee.com.au serves real Calee calendars and is a registered public
// calendar source. Only the legal ROUTES are forbidden.

import 'dart:io';

import 'package:calee_mobile/config/calee_links.dart';
import 'package:flutter_test/flutter_test.dart';

/// A legacy legal URL on any Calee host: the Portal legal routes and the
/// Business/CEWA `/legal/*.html` bundles. Each of these now redirects to
/// calee.com.au, so linking to one from the app would send a user through a
/// redirect to reach a document the app could have named directly.
final _legacyLegalUrl = RegExp(
  r'https?://[a-z0-9.-]*calee\.com\.au/(privacy|terms|legal)(\.html|/legal|\b)',
  caseSensitive: false,
);

/// The canonical routes are, of course, allowed.
bool _isCanonical(String match) =>
    match.startsWith('https://calee.com.au/privacy') ||
    match.startsWith('https://calee.com.au/terms') ||
    match.startsWith('https://calee.com.au/purchase-terms') ||
    match.startsWith('https://calee.com.au/legal');

/// A `//` line comment, so the historical note in calee_links.dart explaining
/// what the constants replaced is not itself a violation. Code is what ships.
bool _isComment(String line) => line.trimLeft().startsWith('//');

void main() {
  test('no production source links to a legacy Calee legal URL', () {
    final offenders = <String>[];

    final dartFiles =
        Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));

    // A guard that scans nothing always passes. Assert it found the tree.
    expect(
      dartFiles.length,
      greaterThan(50),
      reason: 'lib/ scan found suspiciously few Dart files',
    );

    for (final file in dartFiles) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (_isComment(lines[i])) continue;
        for (final m in _legacyLegalUrl.allMatches(lines[i])) {
          final url = m.group(0)!;
          if (_isCanonical(url)) continue;
          offenders.add('${file.path}:${i + 1}  $url');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'These point at a legacy legal URL. Use kCaleeTermsUrl / '
          'kCaleePrivacyUrl from lib/config/calee_links.dart:\n'
          '${offenders.join('\n')}',
    );
  });

  test('the canonical constants are the only legal URLs Mobile declares', () {
    // Both constants are reachable from this test, which is what makes the
    // scan above meaningful: there is one place to change them.
    expect(kCaleeTermsUrl, 'https://calee.com.au/terms/');
    expect(kCaleePrivacyUrl, 'https://calee.com.au/privacy/');
  });
}
