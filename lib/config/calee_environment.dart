import 'package:flutter/foundation.dart';

/// Resolves which Calee Hub backend this build talks to.
///
/// Production builds default safely to [productionBaseUrl]. A
/// development/regression build may point at an *approved non-production*
/// backend at build time with:
///
/// ```
/// flutter build ... \
///   --dart-define=CALEE_REGRESSION=true \
///   --dart-define=CALEE_API_BASE=https://hub-dev.calee.com.au
/// ```
///
/// The same `--dart-define` mechanism works identically for Android and iOS
/// (and for `flutter test`/`flutter drive`, which is how the regression
/// framework selects the backend). No secret is ever part of this
/// configuration -- only a base URL, which is not sensitive.
///
/// ## Backend safety policy
///
/// The whole point of this class is that a normal, production-signed build
/// can never be talked into contacting an arbitrary host, even by a
/// malformed or malicious `--dart-define`. Two orthogonal permissions gate
/// an override, both granted only to a debug or explicitly-regression build
/// ([exposeEnvironment]):
///
///  * **allowNonProduction** -- whether a backend host *other than*
///    [productionBaseUrl] may be selected at all. A production release has
///    this OFF, so it may use *only* `https://hub.calee.com.au`; any other
///    host (however well-formed) is rejected and falls back to production.
///    A non-production backend therefore requires `CALEE_REGRESSION=true`
///    (or a debug build). Approved non-production hosts are additionally
///    restricted to [allowedNonProductionHosts].
///  * **allowInsecure** -- whether a plain-`http` scheme may be used (e.g. a
///    local hub on the LAN). A production release has this OFF too, so it
///    always requires `https`.
///
/// On top of those, an override is rejected in *every* build mode -- release
/// or debug -- when it is not a clean base URL:
///
///  * unparseable, or hostless;
///  * carries user information (`https://user:pass@host`) -- credentials
///    must never ride in a backend URL, and are never logged;
///  * carries a query (`?...`) or fragment (`#...`);
///  * carries a path beyond `/` -- a backend base URL only.
///
/// Any rejected override falls back to [productionBaseUrl], so a typo (or an
/// injected value) in a release build can never silently redirect the app.
///
/// The resolved backend is exposed to the regression framework by
/// [logDiagnostics], which prints a single stable, greppable line -- but only
/// in a debug or regression build, never in a normal production release, and
/// never containing credentials (URLs carrying user info are rejected before
/// they can be resolved/logged). run_ui_suite.py reads that line back to
/// record and verify the backend the app *actually* resolved; it never
/// assumes the build honored the define.
class CaleeEnvironment {
  CaleeEnvironment._();

  /// The production backend. This is the default whenever no valid override
  /// is supplied, in every build mode, and the only host a production release
  /// is permitted to contact.
  static const String productionBaseUrl = 'https://hub.calee.com.au';

  /// The one production host, compared case-insensitively against an
  /// override's host.
  static const String productionHost = 'hub.calee.com.au';

  /// Approved non-production hosts. A regression/debug build may point at one
  /// of these over `https`; a production release may point at none of them.
  /// This is the optional allowed-host list: even with
  /// `CALEE_REGRESSION=true`, an arbitrary HTTPS host is not accepted -- only
  /// a known Calee-owned regression/staging backend.
  static const Set<String> allowedNonProductionHosts = <String>{
    productionHost,
    'hub-dev.calee.com.au',
    'hub-staging.calee.com.au',
    'hub-uat.calee.com.au',
  };

  /// Build-time backend override. Empty (the default) means "use production".
  /// A compile-time constant, so it is baked into the build and resolved
  /// identically on Android and iOS.
  static const String _rawOverride = String.fromEnvironment('CALEE_API_BASE');

  /// Build-time flag that opts a non-debug (e.g. profile) build into the
  /// regression diagnostics and the relaxed (non-production-host and
  /// `http`-allowed) backend rules. Set with
  /// `--dart-define=CALEE_REGRESSION=true`. Never set for a production
  /// release.
  static const bool isRegressionBuild = bool.fromEnvironment(
    'CALEE_REGRESSION',
  );

  /// The production backend as a [Uri].
  static final Uri productionUri = Uri.parse(productionBaseUrl);

  /// Whether this build may log or display the selected environment, target a
  /// non-production backend, or use a plain-`http` backend. True only for a
  /// debug build or an explicitly-regression build; a production release
  /// stays silent about its backend and may contact only production.
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
  /// supplied but was empty/malformed/insecure/off-policy and was discarded
  /// in favour of the safe production default).
  static String get backendSource => describeSource(_rawOverride);

  /// Pure, testable resolution of a raw `CALEE_API_BASE` value. Exposed so
  /// tests can cover the production default, an approved override, and a
  /// rejected override without needing separately-compiled builds.
  ///
  /// [allowInsecure] gates whether a plain-`http` override is accepted;
  /// [allowNonProduction] gates whether a host other than [productionHost]
  /// may be selected at all. Both default to the current build's rules
  /// ([exposeEnvironment]) -- i.e. off for a production release, on for a
  /// debug/regression build.
  static Uri resolveBackend(
    String? rawOverride, {
    bool? allowInsecure,
    bool? allowNonProduction,
  }) {
    final insecureAllowed = allowInsecure ?? exposeEnvironment;
    final nonProductionAllowed = allowNonProduction ?? exposeEnvironment;
    final raw = (rawOverride ?? '').trim();
    if (raw.isEmpty) {
      return productionUri;
    }
    final parsed = Uri.tryParse(raw);
    if (parsed == null ||
        !isAcceptableBackend(
          parsed,
          allowInsecure: insecureAllowed,
          allowNonProduction: nonProductionAllowed,
        )) {
      // Reject and fall back: never let any build -- least of all a release
      // build -- talk to a malformed, hostless, credential-bearing, insecure,
      // or off-policy backend.
      return productionUri;
    }
    return parsed;
  }

  /// Whether [uri] is an acceptable backend under the given permissions.
  ///
  /// Applied in order:
  ///  1. structural safety (host present; no user info, query, fragment, or
  ///     non-root path) -- enforced in *every* mode;
  ///  2. scheme (`https` always; `http` only when [allowInsecure]);
  ///  3. host policy (the production host is always acceptable; any other
  ///     host requires [allowNonProduction], and a non-production `https`
  ///     host must additionally be in [allowedNonProductionHosts]).
  static bool isAcceptableBackend(
    Uri uri, {
    required bool allowInsecure,
    required bool allowNonProduction,
  }) {
    if (!_isStructurallySafeBackend(uri)) {
      return false;
    }
    if (uri.scheme == 'https') {
      // acceptable scheme
    } else if (uri.scheme == 'http') {
      if (!allowInsecure) {
        return false;
      }
    } else {
      return false;
    }

    if (_isProductionHost(uri)) {
      return true;
    }
    if (!allowNonProduction) {
      // A production release may contact only the production host.
      return false;
    }
    if (uri.scheme == 'http') {
      // A relaxed (debug/regression) build already had to opt into `http`
      // via allowInsecure; a local/LAN dev hub can't be enumerated in an
      // allow-list, so an http override is accepted here on the strength of
      // that opt-in. http cannot reach the https production hub.
      return true;
    }
    // A non-production https host must be a known Calee regression/staging
    // backend -- an arbitrary https host is never accepted, even in
    // regression mode.
    return allowedNonProductionHosts.contains(uri.host.toLowerCase());
  }

  /// Structural safety, enforced regardless of build mode. A backend base URL
  /// must have a host and must not carry credentials, a query, a fragment, or
  /// a path beyond `/`.
  static bool _isStructurallySafeBackend(Uri uri) {
    if (uri.host.isEmpty) {
      return false;
    }
    if (uri.userInfo.isNotEmpty) {
      return false;
    }
    if (uri.hasQuery || uri.hasFragment) {
      return false;
    }
    final path = uri.path;
    if (path.isNotEmpty && path != '/') {
      return false;
    }
    return true;
  }

  static bool _isProductionHost(Uri uri) =>
      uri.host.toLowerCase() == productionHost;

  /// See [backendSource]. Pure and testable.
  static String describeSource(
    String? rawOverride, {
    bool? allowInsecure,
    bool? allowNonProduction,
  }) {
    final raw = (rawOverride ?? '').trim();
    if (raw.isEmpty) {
      return 'default';
    }
    final resolved = resolveBackend(
      raw,
      allowInsecure: allowInsecure,
      allowNonProduction: allowNonProduction,
    );
    final parsed = Uri.tryParse(raw);
    if (parsed != null && _sameBackend(resolved, parsed)) {
      return _sameBackend(resolved, productionUri) ? 'default' : 'override';
    }
    return 'override_rejected';
  }

  /// The single stable line the regression framework greps for. Emitted only
  /// when [exposeEnvironment] is true. Contains no secret -- only the resolved
  /// base URL (guaranteed free of user info by [isAcceptableBackend]) and
  /// where it came from.
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
