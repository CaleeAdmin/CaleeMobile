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


## Local release signing setup

Google Play rejects artifacts signed with the debug key. To build a release-signed APK/AAB locally, create `android/key.properties` (do not commit it) with:

```properties
storeFile=../upload-keystore.jks
storePassword=<your-keystore-password>
keyAlias=<your-key-alias>
keyPassword=<your-key-password>
```

Then build with:

```bash
flutter build appbundle --release
# or
flutter build apk --release
```

If `android/key.properties` is not present, release builds can still be signed by setting the `ANDROID_KEYSTORE_PATH`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, and `ANDROID_KEY_PASSWORD` environment variables (for example in CI). If neither source is configured, the build still succeeds but produces an unsigned release artifact.

## GitHub Actions: Manual signed APK build

A manual GitHub workflow is available at `.github/workflows/build-signed-apk.yml`.

### Required repository secrets

Configure these repository secrets before running the workflow:

- `ANDROID_KEYSTORE_BASE64`: Base64-encoded JKS keystore content.
- `ANDROID_KEYSTORE_PATH`: Path to the JKS keystore file (optional if you generate `android/key.properties` with `storeFile`).
- `ANDROID_KEYSTORE_PASSWORD`: Keystore password.
- `ANDROID_KEY_PASSWORD`: Key password.
- `ANDROID_KEY_ALIAS`: Alias of the signing key.

### Run the pipeline

1. Open **Actions** in GitHub.
2. Select **Build Signed APK**.
3. Click **Run workflow**.
4. Optionally override the Flutter version input.
5. Download the `signed-release-apk` artifact after the run succeeds.
