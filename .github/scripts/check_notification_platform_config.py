#!/usr/bin/env python3
"""Guard the native notification platform configuration for CaleeMobile.

This check fails CI when the Android/iOS configuration required for reliable
local calendar-reminder delivery is missing, so a future edit that (for example)
drops a scheduled-notification receiver, the reboot permission, the notification
delegate, or the dedicated status-bar icon is caught before it ships.

Standard library only. Android manifest checks parse the XML (they do not rely
purely on substring matching); iOS Swift checks are intentionally narrow and
explicit. Run:

    python3 .github/scripts/check_notification_platform_config.py selftest
    python3 .github/scripts/check_notification_platform_config.py check

`check` inspects repository files and never modifies them.
"""

from __future__ import annotations

import os
import re
import sys
import xml.etree.ElementTree as ET

ANDROID_NS = "http://schemas.android.com/apk/res/android"
_A = f"{{{ANDROID_NS}}}"

# Repo-relative paths.
MANIFEST_PATH = "android/app/src/main/AndroidManifest.xml"
ICON_DRAWABLE_PATH = "android/app/src/main/res/drawable/ic_stat_calee.xml"
KEEP_XML_PATH = "android/app/src/main/res/raw/keep.xml"
PROGUARD_PATH = "android/app/proguard-rules.pro"
GRADLE_PATH = "android/app/build.gradle.kts"
DART_SERVICE_PATH = "lib/features/notifications/local_calendar_notification_service.dart"
APPDELEGATE_PATH = "ios/Runner/AppDelegate.swift"

ICON_NAME = "ic_stat_calee"

SCHEDULED_RECEIVER = "com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver"
BOOT_RECEIVER = "com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver"

REQUIRED_BOOT_ACTIONS = {
    "android.intent.action.BOOT_COMPLETED",
    "android.intent.action.MY_PACKAGE_REPLACED",
    "android.intent.action.QUICKBOOT_POWERON",
}


# ── Pure check functions (unit-testable: they take file contents) ──────────────


def check_android_manifest(xml_text: str) -> list[str]:
    """Return a list of error strings for the Android manifest content."""
    errors: list[str] = []
    try:
        root = ET.fromstring(xml_text)
    except ET.ParseError as exc:  # pragma: no cover - exercised via selftest
        return [f"AndroidManifest.xml is not valid XML: {exc}"]

    # Permissions.
    permissions = {
        el.get(f"{_A}name") for el in root.findall("uses-permission")
    }
    for required in (
        "android.permission.POST_NOTIFICATIONS",
        "android.permission.RECEIVE_BOOT_COMPLETED",
    ):
        if required not in permissions:
            errors.append(f"AndroidManifest.xml missing <uses-permission> {required}")

    application = root.find("application")
    if application is None:
        errors.append("AndroidManifest.xml has no <application> element")
        return errors

    receivers = {
        el.get(f"{_A}name"): el for el in application.findall("receiver")
    }

    # ScheduledNotificationReceiver — present and not exported.
    if SCHEDULED_RECEIVER not in receivers:
        errors.append(f"AndroidManifest.xml missing <receiver> {SCHEDULED_RECEIVER}")
    elif receivers[SCHEDULED_RECEIVER].get(f"{_A}exported") != "false":
        errors.append(
            f"{SCHEDULED_RECEIVER} must declare android:exported=\"false\""
        )

    # ScheduledNotificationBootReceiver — present, not exported, correct actions.
    if BOOT_RECEIVER not in receivers:
        errors.append(f"AndroidManifest.xml missing <receiver> {BOOT_RECEIVER}")
    else:
        boot = receivers[BOOT_RECEIVER]
        if boot.get(f"{_A}exported") != "false":
            errors.append(
                f"{BOOT_RECEIVER} must declare android:exported=\"false\""
            )
        actions = {
            el.get(f"{_A}name")
            for intent_filter in boot.findall("intent-filter")
            for el in intent_filter.findall("action")
        }
        for action in sorted(REQUIRED_BOOT_ACTIONS):
            if action not in actions:
                errors.append(
                    f"{BOOT_RECEIVER} intent-filter missing action {action}"
                )
    return errors


def check_dart_references_icon(dart_text: str) -> list[str]:
    """The Dart notification service must reference the dedicated icon."""
    if ICON_NAME not in dart_text:
        return [
            f"{DART_SERVICE_PATH} does not reference notification icon "
            f"'{ICON_NAME}'"
        ]
    return []


def check_keep_xml(keep_text: str) -> list[str]:
    """Resource-keep config must retain the notification drawable."""
    errors: list[str] = []
    try:
        ET.fromstring(keep_text)
    except ET.ParseError as exc:
        return [f"{KEEP_XML_PATH} is not valid XML: {exc}"]
    if f"@drawable/{ICON_NAME}" not in keep_text:
        errors.append(
            f"{KEEP_XML_PATH} must keep @drawable/{ICON_NAME} from resource "
            "shrinking"
        )
    return errors


def check_proguard(proguard_text: str) -> list[str]:
    """Release ProGuard rules must include the GSON rules the plugin needs."""
    errors: list[str] = []
    # flutter_local_notifications 17.2.4 persists scheduled notifications with
    # GSON reflection; the generic-signature attribute and TypeToken keeps are
    # the load-bearing rules.
    if "-keepattributes Signature" not in proguard_text:
        errors.append(f"{PROGUARD_PATH} missing GSON rule '-keepattributes Signature'")
    if "com.google.gson" not in proguard_text:
        errors.append(f"{PROGUARD_PATH} missing GSON keep rules")
    return errors


def check_gradle_wires_proguard(gradle_text: str) -> list[str]:
    """The release build type must wire in proguard-rules.pro."""
    errors: list[str] = []
    if "proguard-rules.pro" not in gradle_text:
        errors.append(
            f"{GRADLE_PATH} release build does not reference proguard-rules.pro"
        )
    if "isMinifyEnabled = true" not in gradle_text:
        errors.append(
            f"{GRADLE_PATH} release build does not enable code shrinking "
            "(isMinifyEnabled = true)"
        )
    return errors


def check_ios_appdelegate(swift_text: str) -> list[str]:
    """iOS: UserNotifications import, delegate assignment inside launch, and the
    existing implicit-engine registration must all be present."""
    errors: list[str] = []
    if not re.search(r"^\s*import\s+UserNotifications\b", swift_text, re.MULTILINE):
        errors.append(f"{APPDELEGATE_PATH} missing 'import UserNotifications'")

    launch_body = _extract_launch_body(swift_text)
    delegate_re = re.compile(
        r"UNUserNotificationCenter\.current\(\)\s*\.delegate\s*="
    )
    if launch_body is None:
        errors.append(
            f"{APPDELEGATE_PATH} has no didFinishLaunchingWithOptions method"
        )
    elif not delegate_re.search(launch_body):
        errors.append(
            f"{APPDELEGATE_PATH} does not assign "
            "UNUserNotificationCenter.current().delegate inside "
            "didFinishLaunchingWithOptions"
        )

    if "didInitializeImplicitFlutterEngine" not in swift_text:
        errors.append(
            f"{APPDELEGATE_PATH} missing FlutterImplicitEngine registration "
            "(didInitializeImplicitFlutterEngine)"
        )
    if "GeneratedPluginRegistrant.register" not in swift_text:
        errors.append(
            f"{APPDELEGATE_PATH} missing GeneratedPluginRegistrant.register call"
        )
    return errors


def _extract_launch_body(swift_text: str) -> str | None:
    """Return the brace-balanced body of didFinishLaunchingWithOptions, or None."""
    marker = swift_text.find("didFinishLaunchingWithOptions")
    if marker == -1:
        return None
    # Find the opening brace of the function body after the signature/return type.
    brace = swift_text.find("{", marker)
    if brace == -1:
        return None
    depth = 0
    for i in range(brace, len(swift_text)):
        ch = swift_text[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return swift_text[brace + 1 : i]
    return None


# ── Repository-file orchestration ──────────────────────────────────────────────


def _read(root: str, rel: str) -> str | None:
    path = os.path.join(root, rel)
    if not os.path.isfile(path):
        return None
    with open(path, "r", encoding="utf-8") as handle:
        return handle.read()


def run_check(root: str) -> list[str]:
    """Run every check against repository files under [root]."""
    errors: list[str] = []

    manifest = _read(root, MANIFEST_PATH)
    if manifest is None:
        errors.append(f"missing file: {MANIFEST_PATH}")
    else:
        errors.extend(check_android_manifest(manifest))

    if _read(root, ICON_DRAWABLE_PATH) is None:
        errors.append(
            f"missing dedicated notification drawable: {ICON_DRAWABLE_PATH}"
        )

    dart = _read(root, DART_SERVICE_PATH)
    if dart is None:
        errors.append(f"missing file: {DART_SERVICE_PATH}")
    else:
        errors.extend(check_dart_references_icon(dart))

    keep = _read(root, KEEP_XML_PATH)
    if keep is None:
        errors.append(f"missing release resource-keep config: {KEEP_XML_PATH}")
    else:
        errors.extend(check_keep_xml(keep))

    proguard = _read(root, PROGUARD_PATH)
    if proguard is None:
        errors.append(f"missing release ProGuard config: {PROGUARD_PATH}")
    else:
        errors.extend(check_proguard(proguard))

    gradle = _read(root, GRADLE_PATH)
    if gradle is None:
        errors.append(f"missing file: {GRADLE_PATH}")
    else:
        errors.extend(check_gradle_wires_proguard(gradle))

    appdelegate = _read(root, APPDELEGATE_PATH)
    if appdelegate is None:
        errors.append(f"missing file: {APPDELEGATE_PATH}")
    else:
        errors.extend(check_ios_appdelegate(appdelegate))

    return errors


# ── Self-test ──────────────────────────────────────────────────────────────────

_GOOD_MANIFEST = """<manifest xmlns:android="http://schemas.android.com/apk/res/android">
  <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
  <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />
  <application android:label="Calee">
    <receiver android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver" android:exported="false" />
    <receiver android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver" android:exported="false">
      <intent-filter>
        <action android:name="android.intent.action.BOOT_COMPLETED" />
        <action android:name="android.intent.action.MY_PACKAGE_REPLACED" />
        <action android:name="android.intent.action.QUICKBOOT_POWERON" />
        <action android:name="com.htc.intent.action.QUICKBOOT_POWERON" />
      </intent-filter>
    </receiver>
  </application>
</manifest>
"""

_GOOD_APPDELEGATE = """import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
  func didInitializeImplicitFlutterEngine(_ b: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: b.pluginRegistry)
  }
}
"""


def _run_selftest() -> int:
    failures: list[str] = []

    def expect(name: str, got: list[str], want_empty: bool) -> None:
        ok = (len(got) == 0) if want_empty else (len(got) > 0)
        if not ok:
            failures.append(f"selftest '{name}' failed: {got}")

    # Good inputs → no errors.
    expect("good manifest", check_android_manifest(_GOOD_MANIFEST), True)
    expect("good appdelegate", check_ios_appdelegate(_GOOD_APPDELEGATE), True)
    expect(
        "good keep",
        check_keep_xml('<resources xmlns:tools="x" tools:keep="@drawable/ic_stat_calee" />'),
        True,
    )
    expect(
        "good proguard",
        check_proguard("-keepattributes Signature\n-keep class com.google.gson.**"),
        True,
    )
    expect(
        "good gradle",
        check_gradle_wires_proguard('isMinifyEnabled = true\nproguardFiles("proguard-rules.pro")'),
        True,
    )
    expect("good dart", check_dart_references_icon("const icon = 'ic_stat_calee';"), True)

    # Missing reboot permission → error.
    no_boot_perm = _GOOD_MANIFEST.replace(
        '<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />',
        "",
    )
    expect("missing reboot permission", check_android_manifest(no_boot_perm), False)

    # Exported boot receiver → error.
    exported = _GOOD_MANIFEST.replace(
        'ScheduledNotificationBootReceiver" android:exported="false"',
        'ScheduledNotificationBootReceiver" android:exported="true"',
    )
    expect("exported boot receiver", check_android_manifest(exported), False)

    # Missing a required boot action → error.
    no_action = _GOOD_MANIFEST.replace(
        '<action android:name="android.intent.action.MY_PACKAGE_REPLACED" />', ""
    )
    expect("missing package-replaced action", check_android_manifest(no_action), False)

    # Missing receiver entirely → error.
    no_receiver = _GOOD_MANIFEST.replace(
        '<receiver android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver" android:exported="false" />',
        "",
    )
    expect("missing scheduled receiver", check_android_manifest(no_receiver), False)

    # iOS: delegate assignment removed → error.
    no_delegate = _GOOD_APPDELEGATE.replace(
        "UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate",
        "",
    )
    expect("missing ios delegate", check_ios_appdelegate(no_delegate), False)

    # iOS: import removed → error.
    no_import = _GOOD_APPDELEGATE.replace("import UserNotifications\n", "")
    expect("missing ios import", check_ios_appdelegate(no_import), False)

    # iOS: implicit-engine registration removed → error.
    no_engine = _GOOD_APPDELEGATE.replace("didInitializeImplicitFlutterEngine", "somethingElse")
    expect("missing implicit engine", check_ios_appdelegate(no_engine), False)

    if failures:
        for failure in failures:
            print(f"::error::{failure}")
        print(f"SELFTEST FAILED: {len(failures)} case(s)")
        return 1
    print("SELFTEST PASSED")
    return 0


# ── Entry point ────────────────────────────────────────────────────────────────


def _repo_root() -> str:
    # This file lives at <root>/.github/scripts/, so the root is two levels up.
    return os.path.abspath(
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
    )


def main(argv: list[str]) -> int:
    command = argv[1] if len(argv) > 1 else "check"
    if command == "selftest":
        return _run_selftest()
    if command == "check":
        root = argv[2] if len(argv) > 2 else _repo_root()
        errors = run_check(root)
        if errors:
            for error in errors:
                # GitHub Actions annotation.
                print(f"::error::{error}")
            print(
                f"\nNotification platform-config check FAILED with "
                f"{len(errors)} problem(s)."
            )
            return 1
        print("Notification platform-config check passed.")
        return 0
    print(f"unknown command: {command!r} (use 'check' or 'selftest')")
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
