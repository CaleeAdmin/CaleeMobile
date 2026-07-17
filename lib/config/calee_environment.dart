import 'package:flutter/foundation.dart';

/// Resolves which Calee Hub backend this build talks to.
///
/// Production builds default safely to [productionBaseUrl]. A
/// development/regression build may point at a non-production backend at
/// build time with:
///
/// ```
/// flutter build ... --dart-define=CALEE_API_BASE=https://hub-dev.calee.com.au
/// ```
///
/// The same `--dart-define` mechanism works identically for Android and iOS
/// (and for `flutter test`/`flutter drive`, which is how the regression
/// framework selects the backend). No secret is ever part of this
/// configuration -- only a base URL, which is not sensitive.
///
/// Safety rules enforced here:
///
///  * An empty override falls back to [productionBaseUrl] -- a release build
///    can never end up pointing at an empty/blank backend.
///  * A malformed override (unparseable, no host, or a non-`https` scheme in a
///    release build) is rejected and also falls back to [productionBaseUrl],
///    so a typo in a release build's define can never silently redirect the
///    app at an invalid URL.
///  * Plain `http` is accepted only in debug/regression builds (e.g. a local
///    hub on the LAN); a release build always requires `https`.
///
/// The resolved backend is exposed to the regression framework by
/// [logDiagnostics], which prints a single stable, greppable line -- but only
/// in a debug or regression build, never in a normal production release.
/// run_ui_suite.py reads that line back to record and verify the backend the
/// app *actually* resolved; it never assumes the build honored the define.
class CaleeEnvironment {
  CaleeEnvironment._();

  /// The production backend. This is the default whenever no valid override
  /// is supplied, in every build mode.
  static const String productionBaseUrl = 'https://hub.calee.com.au';

  /// Build-time backend override. Empty (the default) means "use production".
  /// A compile-time constant, so it is baked into the build and resolved
  /// identically on Android and iOS.
  static const String _rawOverride = String.fromEnvironment('CALEE_API_BASE');

  /// Build-time flag that opts a non-debug (e.g. profile) build into the
  /// regression diagnostics and the relaxed (`http`-allowed) backend rules.
  /// Set with `--dart-define=CALEE_REGRESSION=true`. Never set for a
  /// production release.
  static const bool isRegressionBuild = bool.fromEnvironment(
    'CALEE_REGRESSION',
  );

  /// The production backend as a [Uri].
  static final Uri productionUri = Uri.parse(productionBaseUrl);

  /// Whether this build may log or display the selected environment. True
  /// only for a debug build or an explicitly-regression build; a production
  /// release stays silent about its backend.
  static bool get exposeEnvironment => kDebugMode || isRegressionBuild;

  /// The backend base URI the app talks to, after applying every safety rule
  /// documented on this class.
  static Uri get apiBaseUri => resolveBackend(_rawOverride);

  /// The resolved backend as a string.
  static String get resolvedBaseUrl => apiBaseUri.toString();

  /// Whether the resolved backend is the production backend.
  static bool get isProductionBackend =>
      _sameBackend(apiBaseUri, productionUri);

  /// Where the resolved backend came from: `default` (no override, or an
  /// override that matches production), `override` (a valid, accepted
  /// non-production override), or `override_rejected` (an override was
  /// supplied but was empty/malformed/insecure and was discarded in favour of
  /// the safe production default).
  static String get backendSource => describeSource(_rawOverride);

  /// Pure, testable resolution of a raw `CALEE_API_BASE` value. Exposed so
  /// tests can cover the production default, a valid override, and an invalid
  /// override without needing three separately-compiled builds.
  ///
  /// [allowInsecure] gates whether a plain-`http` override is accepted; it
  /// defaults to the current build's rules (debug/regression only).
  static Uri resolveBackend(String? rawOverride, {bool? allowInsecure}) {
    final insecureAllowed = allowInsecure ?? exposeEnvironment;
    final raw = (rawOverride ?? '').trim();
    if (raw.isEmpty) {
      return productionUri;
    }
    final parsed = Uri.tryParse(raw);
    if (parsed == null ||
        !isAcceptableBackend(parsed, allowInsecure: insecureAllowed)) {
      // Reject and fall back: never let any build -- least of all a release
      // build -- talk to a malformed, hostless, or insecure backend.
      return productionUri;
    }
    return parsed;
  }

  /// Whether [uri] is an acceptable backend: it must have a host and use
  /// `https` (or `http` when [allowInsecure] is true).
  static bool isAcceptableBackend(Uri uri, {required bool allowInsecure}) {
    if (uri.host.isEmpty) {
      return false;
    }
    if (uri.scheme == 'https') {
      return true;
    }
    if (uri.scheme == 'http') {
      return allowInsecure;
    }
    return false;
  }

  /// See [backendSource]. Pure and testable.
  static String describeSource(String? rawOverride, {bool? allowInsecure}) {
    final raw = (rawOverride ?? '').trim();
    if (raw.isEmpty) {
      return 'default';
    }
    final resolved = resolveBackend(raw, allowInsecure: allowInsecure);
    final parsed = Uri.tryParse(raw);
    if (parsed != null && _sameBackend(resolved, parsed)) {
      return _sameBackend(resolved, productionUri) ? 'default' : 'override';
    }
    return 'override_rejected';
  }

  /// The single stable line the regression framework greps for. Emitted only
  /// when [exposeEnvironment] is true. Contains no secret -- only the resolved
  /// base URL and where it came from.
  static String diagnosticLine() {
    return 'CALEE_ENV backend=$resolvedBaseUrl '
        'production=$isProductionBackend source=$backendSource';
  }

  /// Prints [diagnosticLine] in debug/regression builds; a no-op in a
  /// production release.
  static void logDiagnostics() {
    if (!exposeEnvironment) {
      return;
    }
    debugPrint(diagnosticLine());
  }

  static bool _sameBackend(Uri a, Uri b) {
    String norm(Uri u) {
      final s = u.toString();
      return s.endsWith('/') ? s.substring(0, s.length - 1) : s;
    }

    return norm(a) == norm(b);
  }
}
