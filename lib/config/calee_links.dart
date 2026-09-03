/// Canonical customer-facing Calee-for-home marketing site, opened from
/// in-app promotions (e.g. the calendar decision page and the local
/// calendars sheet). Opening it must never consume a pending calendar
/// intent or sign the user in.
const String kCaleeForHomeUrl = 'https://calee.com.au/';

/// The canonical Calee Terms of Use.
///
/// calee.com.au is the single public home for the Calee legal documents
/// (CaleeAdmin/calee-hub-web#107). These used to be three separate
/// hard-coded `https://portal.calee.com.au/terms` string literals in
/// Welcome, Login and Create Account, which is exactly how they came to
/// point at a Portal-specific document that does not describe a household
/// using the mobile app at all.
///
/// One constant per document, used by every surface that offers the link.
const String kCaleeTermsUrl = 'https://calee.com.au/terms/';

/// The canonical Calee Privacy Policy.
///
/// This is the URL the Apple App Store and Google Play listings must carry.
/// Changing it here does NOT change either store listing -- that is a manual
/// action in App Store Connect and the Play Console. See
/// docs/RELEASE_CHECKLIST.md.
const String kCaleePrivacyUrl = 'https://calee.com.au/privacy/';
