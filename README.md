# caleesync

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Lab: Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Cookbook: Useful Flutter samples](https://docs.flutter.dev/cookbook)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## GitHub Actions: Manual signed APK build

A manual GitHub workflow is available at `.github/workflows/build-signed-apk.yml`.

### Required repository secrets

Configure these repository secrets before running the workflow:

- `ANDROID_KEYSTORE_BASE64`: Base64-encoded JKS keystore content.
- `ANDROID_STORE_PASSWORD`: Keystore password.
- `ANDROID_KEY_PASSWORD`: Key password.
- `ANDROID_KEY_ALIAS`: Alias of the signing key.

### Run the pipeline

1. Open **Actions** in GitHub.
2. Select **Build Signed APK**.
3. Click **Run workflow**.
4. Optionally override the Flutter version input.
5. Download the `signed-release-apk` artifact after the run succeeds.
