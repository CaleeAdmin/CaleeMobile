#!/usr/bin/env python3
"""Verify the packaged Android release APK's notification configuration.

check_notification_platform_config.py guards the repository *source* files
(AndroidManifest.xml, proguard-rules.pro, keep.xml, ...). It cannot catch a
regression introduced by R8/resource-shrinking itself — for example the
release build silently stripping the ScheduledNotificationBootReceiver or the
notification icon because a shrinker rule was too narrow. This script
inspects the *built* release APK instead, after `flutter build apk --release`
has produced it.

Standard library only. Shells out to the Android SDK's `apkanalyzer` (manifest,
packaged-file listing + DEX defined-class listing) and `aapt2`/`aapt`
(resource table) via subprocess.
Never writes to the APK. Run:

    python3 .github/scripts/check_notification_release_apk.py selftest
    python3 .github/scripts/check_notification_release_apk.py check \\
        build/app/outputs/flutter-apk/app-release.apk

`check` only ever reads the APK and the Android SDK tool output.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET

ANDROID_NS = "http://schemas.android.com/apk/res/android"
_A = f"{{{ANDROID_NS}}}"

APPLICATION_ID = "au.com.calee.mobile"
PUBSPEC_PATH = "pubspec.yaml"
DEFAULT_APK_PATH = "build/app/outputs/flutter-apk/app-release.apk"

SCHEDULED_RECEIVER = "com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver"
BOOT_RECEIVER = "com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver"

REQUIRED_PERMISSIONS = {
    "android.permission.POST_NOTIFICATIONS",
    "android.permission.RECEIVE_BOOT_COMPLETED",
}

REQUIRED_BOOT_ACTIONS = {
    "android.intent.action.BOOT_COMPLETED",
    "android.intent.action.MY_PACKAGE_REPLACED",
    "android.intent.action.QUICKBOOT_POWERON",
}

ICON_RESOURCE = "drawable/ic_stat_calee"

# Receiver classes that must survive R8 in the release DEX. The packaged
# manifest declaring them is not enough — if R8 stripped the classes, Android
# would throw ClassNotFoundException when the alarm/boot broadcast fires.
REQUIRED_DEX_CLASSES = {
    SCHEDULED_RECEIVER,
    BOOT_RECEIVER,
}


# ── Pure check functions (unit-testable: they take captured tool output) ───


def check_packaged_manifest(xml_text: str) -> list[str]:
    """Check the `apkanalyzer manifest print` XML output of the packaged APK."""
    errors: list[str] = []
    try:
        root = ET.fromstring(xml_text)
    except ET.ParseError as exc:  # pragma: no cover - exercised via selftest
        return [f"packaged AndroidManifest.xml is not valid XML: {exc}"]

    package = root.get("package")
    if package != APPLICATION_ID:
        errors.append(
            f"packaged manifest application id is {package!r}, expected "
            f"{APPLICATION_ID!r}"
        )

    permissions = {el.get(f"{_A}name") for el in root.findall("uses-permission")}
    for required in sorted(REQUIRED_PERMISSIONS):
        if required not in permissions:
            errors.append(f"packaged manifest missing <uses-permission> {required}")

    application = root.find("application")
    if application is None:
        errors.append("packaged manifest has no <application> element")
        return errors

    receivers = {el.get(f"{_A}name"): el for el in application.findall("receiver")}

    if SCHEDULED_RECEIVER not in receivers:
        errors.append(f"packaged manifest missing <receiver> {SCHEDULED_RECEIVER}")
    elif receivers[SCHEDULED_RECEIVER].get(f"{_A}exported") != "false":
        errors.append(
            f"packaged {SCHEDULED_RECEIVER} must declare android:exported=\"false\""
        )

    if BOOT_RECEIVER not in receivers:
        errors.append(f"packaged manifest missing <receiver> {BOOT_RECEIVER}")
    else:
        boot = receivers[BOOT_RECEIVER]
        if boot.get(f"{_A}exported") != "false":
            errors.append(
                f"packaged {BOOT_RECEIVER} must declare android:exported=\"false\""
            )
        actions = {
            el.get(f"{_A}name")
            for intent_filter in boot.findall("intent-filter")
            for el in intent_filter.findall("action")
        }
        for action in sorted(REQUIRED_BOOT_ACTIONS):
            if action not in actions:
                errors.append(
                    f"packaged {BOOT_RECEIVER} intent-filter missing action {action}"
                )

    return errors


def check_version(
    xml_text: str, expected_version_name: str | None, expected_version_code: str | None
) -> list[str]:
    """The packaged versionName/versionCode must match pubspec.yaml."""
    try:
        root = ET.fromstring(xml_text)
    except ET.ParseError as exc:  # pragma: no cover - exercised via selftest
        return [f"packaged AndroidManifest.xml is not valid XML: {exc}"]

    errors: list[str] = []
    version_name = root.get(f"{_A}versionName")
    version_code = root.get(f"{_A}versionCode")
    if expected_version_name is not None and version_name != expected_version_name:
        errors.append(
            f"packaged versionName is {version_name!r}, expected "
            f"{expected_version_name!r} (from {PUBSPEC_PATH})"
        )
    if expected_version_code is not None and version_code != expected_version_code:
        errors.append(
            f"packaged versionCode is {version_code!r}, expected "
            f"{expected_version_code!r} (from {PUBSPEC_PATH})"
        )
    return errors


def check_packaged_icon_resource(aapt2_resources_text: str) -> list[str]:
    """`aapt2 dump resources <apk>` output must still list the notification icon."""
    if ICON_RESOURCE not in aapt2_resources_text:
        return [
            f"packaged resource table does not contain {ICON_RESOURCE} "
            "(resource shrinking likely stripped the notification icon)"
        ]
    return []


def extract_icon_backing_file(aapt2_resources_text: str) -> str | None:
    """Pull the packaged file path (e.g. 'res/Ry.xml') for the icon resource
    out of `aapt2 dump resources` output. Resource shrinking renames resource
    paths, so the file name itself cannot be hard-coded."""
    in_block = False
    for raw_line in aapt2_resources_text.splitlines():
        line = raw_line.strip()
        if line.startswith("resource ") and ICON_RESOURCE in line:
            in_block = True
            continue
        if not in_block:
            continue
        if line.startswith("resource "):
            break  # next resource entry — the icon block has ended
        if "(file)" in line:
            for part in line.split():
                if part.startswith("res/"):
                    return part
    return None


def check_icon_file_packaged(backing_file: str | None, apkanalyzer_files_text: str) -> list[str]:
    """The icon's backing resource file must actually be present in the APK's
    file listing, not just referenced by a resource-table entry."""
    if backing_file is None:
        return [
            f"could not locate a packaged file backing {ICON_RESOURCE} in the "
            "aapt2 resource dump"
        ]
    packaged = {line.strip() for line in apkanalyzer_files_text.splitlines()}
    if f"/{backing_file}" not in packaged:
        return [
            f"packaged APK does not contain the {ICON_RESOURCE} backing file "
            f"/{backing_file}"
        ]
    return []


def parse_dex_defined_classes(dex_packages_text: str) -> set[str]:
    """Parse `apkanalyzer dex packages --defined-only <apk>` output into the
    set of fully-qualified class names defined in the APK's DEX files.

    Each line looks like:

        C d 8	22	1042	com.example.Foo

    i.e. node type ("P" package / "C" class / "M" method / "F" field), a
    defined/removed flag, three numeric columns (defined methods, referenced
    methods, byte size), then the fully-qualified name. Only "C" (class) rows
    marked defined ("d") are collected; the name is the final
    whitespace-separated field, so method/field rows (whose names contain
    spaces and parentheses) are excluded by the node-type filter, not by
    guessing at the name format.
    """
    classes: set[str] = set()
    for raw_line in dex_packages_text.splitlines():
        parts = raw_line.split()
        if len(parts) < 6:
            continue
        node_type, state = parts[0], parts[1]
        if node_type != "C" or state != "d":
            continue
        classes.add(parts[-1])
    return classes


def check_dex_receiver_classes(defined_classes: set[str]) -> list[str]:
    """Both scheduled-notification receiver classes must be *defined* in the
    release DEX — manifest declarations alone do not prove R8 kept the code."""
    errors: list[str] = []
    for required in sorted(REQUIRED_DEX_CLASSES):
        if required not in defined_classes:
            errors.append(
                f"release DEX does not define class {required} (declared in "
                "the manifest but stripped by R8/minification — the receiver "
                "would crash with ClassNotFoundException at delivery time)"
            )
    return errors


def parse_pubspec_version(pubspec_text: str) -> tuple[str | None, str | None]:
    """Parse the top-level `version: X.Y.Z+N` line from pubspec.yaml."""
    for line in pubspec_text.splitlines():
        match = re.match(r"^version:\s*(\S+)\s*$", line)
        if match:
            raw = match.group(1)
            if "+" in raw:
                name, code = raw.split("+", 1)
                return name, code
            return raw, None
    return None, None


# ── Android SDK tool discovery / invocation ─────────────────────────────────


def _find_tool(name: str) -> str | None:
    """Locate an Android SDK command-line tool by name: PATH first, then the
    usual cmdline-tools/build-tools layouts under $ANDROID_SDK_ROOT /
    $ANDROID_HOME (newest version first)."""
    found = shutil.which(name)
    if found:
        return found

    sdk_root = os.environ.get("ANDROID_SDK_ROOT") or os.environ.get("ANDROID_HOME")
    if not sdk_root:
        return None

    candidates: list[str] = []
    cmdline_tools = os.path.join(sdk_root, "cmdline-tools")
    if os.path.isdir(cmdline_tools):
        for entry in sorted(os.listdir(cmdline_tools), reverse=True):
            candidates.append(os.path.join(cmdline_tools, entry, "bin", name))
    build_tools = os.path.join(sdk_root, "build-tools")
    if os.path.isdir(build_tools):
        for entry in sorted(os.listdir(build_tools), reverse=True):
            candidates.append(os.path.join(build_tools, entry, name))

    for candidate in candidates:
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


def _run(cmd: list[str]) -> str:
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise RuntimeError(
            f"command failed ({result.returncode}): {' '.join(cmd)}\n"
            f"{result.stderr.strip()}"
        )
    return result.stdout


# ── Repository / APK orchestration ──────────────────────────────────────────


def _expected_version(root: str) -> tuple[str | None, str | None]:
    pubspec = os.path.join(root, PUBSPEC_PATH)
    if not os.path.isfile(pubspec):
        return None, None
    with open(pubspec, "r", encoding="utf-8") as handle:
        return parse_pubspec_version(handle.read())


def run_check(apk_path: str, repo_root: str) -> list[str]:
    """Inspect the packaged release APK at [apk_path]. Never modifies it."""
    if not os.path.isfile(apk_path):
        return [
            f"release APK not found at {apk_path} — build it first with "
            "'flutter build apk --release'"
        ]

    apkanalyzer = _find_tool("apkanalyzer")
    if apkanalyzer is None:
        return [
            "apkanalyzer not found (checked PATH and $ANDROID_SDK_ROOT/"
            "$ANDROID_HOME cmdline-tools); cannot inspect the packaged release APK"
        ]

    errors: list[str] = []

    try:
        manifest_xml = _run([apkanalyzer, "manifest", "print", apk_path])
    except RuntimeError as exc:
        return [str(exc)]

    errors.extend(check_packaged_manifest(manifest_xml))

    expected_name, expected_code = _expected_version(repo_root)
    errors.extend(check_version(manifest_xml, expected_name, expected_code))

    # The manifest can declare a receiver whose class R8 nevertheless removed;
    # prove the classes are really defined in the packaged DEX.
    try:
        dex_packages_text = _run(
            [apkanalyzer, "dex", "packages", "--defined-only", apk_path]
        )
    except RuntimeError as exc:
        errors.append(str(exc))
    else:
        errors.extend(
            check_dex_receiver_classes(parse_dex_defined_classes(dex_packages_text))
        )

    aapt2 = _find_tool("aapt2") or _find_tool("aapt")
    if aapt2 is None:
        errors.append(
            "aapt2/aapt not found; cannot verify the packaged notification "
            "icon resource"
        )
        return errors

    try:
        resources_text = _run([aapt2, "dump", "resources", apk_path])
    except RuntimeError as exc:
        errors.append(str(exc))
        return errors

    errors.extend(check_packaged_icon_resource(resources_text))
    backing_file = extract_icon_backing_file(resources_text)

    try:
        files_text = _run([apkanalyzer, "files", "list", apk_path])
    except RuntimeError as exc:
        errors.append(str(exc))
        return errors

    errors.extend(check_icon_file_packaged(backing_file, files_text))

    return errors


# ── Self-test (pure parsing functions only — no APK or SDK required) ───────

_GOOD_MANIFEST = """<?xml version="1.0" encoding="utf-8"?>
<manifest
    xmlns:android="http://schemas.android.com/apk/res/android"
    android:versionCode="24"
    android:versionName="0.0.24"
    package="au.com.calee.mobile">

    <uses-permission
        android:name="android.permission.POST_NOTIFICATIONS" />

    <uses-permission
        android:name="android.permission.RECEIVE_BOOT_COMPLETED" />

    <application
        android:label="Calee">

        <receiver
            android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver"
            android:exported="false" />

        <receiver
            android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver"
            android:exported="false">

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

_GOOD_AAPT2_RESOURCES = """Package name=au.com.calee.mobile id=7f
  type drawable id=07
    resource 0x7f070074 drawable/ic_stat_calee
      () (file) res/Ry.xml type=XML
    resource 0x7f070075 drawable/launch_background
      () (file) res/Zn.xml type=XML
"""

_GOOD_APKANALYZER_FILES = """/res/
/res/Ry.xml
/res/Zn.xml
/AndroidManifest.xml
/classes.dex
"""

_GOOD_DEX_PACKAGES = """P d 41\t173\t12886\tcom.dexterous.flutterlocalnotifications
C d 12\t48\t4102\tcom.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver
C d 9\t31\t2077\tcom.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver
C d 20\t94\t6707\tcom.dexterous.flutterlocalnotifications.FlutterLocalNotificationsPlugin
M d 1\t1\t68\tvoid com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver.onReceive(android.content.Context, android.content.Intent)
P d 120\t455\t60110\tio.flutter
C d 30\t101\t9552\tio.flutter.app.FlutterApplication
"""


def _run_selftest() -> int:
    failures: list[str] = []

    def expect(name: str, got: list[str], want_empty: bool) -> None:
        ok = (len(got) == 0) if want_empty else (len(got) > 0)
        if not ok:
            failures.append(f"selftest '{name}' failed: {got}")

    # Good inputs → no errors.
    expect("good manifest", check_packaged_manifest(_GOOD_MANIFEST), True)
    expect("good version", check_version(_GOOD_MANIFEST, "0.0.24", "24"), True)
    expect("version not checked when unknown", check_version(_GOOD_MANIFEST, None, None), True)
    expect(
        "good icon resource", check_packaged_icon_resource(_GOOD_AAPT2_RESOURCES), True
    )
    backing = extract_icon_backing_file(_GOOD_AAPT2_RESOURCES)
    if backing != "res/Ry.xml":
        failures.append(f"selftest 'extract backing file' failed: got {backing!r}")
    expect(
        "good icon file packaged",
        check_icon_file_packaged(backing, _GOOD_APKANALYZER_FILES),
        True,
    )
    name, code = parse_pubspec_version("name: calee_mobile\nversion: 0.0.24+24\n")
    if (name, code) != ("0.0.24", "24"):
        failures.append(f"selftest 'parse pubspec version' failed: got {(name, code)!r}")

    # Both receiver classes defined in DEX → no errors.
    defined = parse_dex_defined_classes(_GOOD_DEX_PACKAGES)
    if SCHEDULED_RECEIVER not in defined or BOOT_RECEIVER not in defined:
        failures.append(f"selftest 'parse dex defined classes' failed: got {sorted(defined)!r}")
    expect("good dex receiver classes", check_dex_receiver_classes(defined), True)

    # Method rows must not be mistaken for class definitions.
    method_only = "M d 1\t1\t68\tvoid com.example.Foo.bar()\n"
    if parse_dex_defined_classes(method_only):
        failures.append("selftest 'dex method row ignored' failed")

    # A class R8 removed (state 'r' under --show-removed) must not count.
    removed = _GOOD_DEX_PACKAGES.replace(
        "C d 9\t31\t2077\tcom.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver",
        "C r 9\t31\t2077\tcom.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver",
    )
    expect(
        "dex removed boot receiver",
        check_dex_receiver_classes(parse_dex_defined_classes(removed)),
        False,
    )

    # Scheduled receiver absent from the DEX listing entirely → error.
    stripped_dex = "\n".join(
        line
        for line in _GOOD_DEX_PACKAGES.splitlines()
        if not line.endswith(SCHEDULED_RECEIVER)
    )
    expect(
        "dex missing scheduled receiver",
        check_dex_receiver_classes(parse_dex_defined_classes(stripped_dex)),
        False,
    )

    # Empty tool output (e.g. wrong file) → both classes reported missing.
    empty_dex_errors = check_dex_receiver_classes(parse_dex_defined_classes(""))
    if len(empty_dex_errors) != 2:
        failures.append(
            f"selftest 'dex empty output' failed: got {empty_dex_errors!r}"
        )

    # Wrong application id → error.
    wrong_id = _GOOD_MANIFEST.replace(
        'package="au.com.calee.mobile"', 'package="com.example.other"'
    )
    expect("wrong application id", check_packaged_manifest(wrong_id), False)

    # Missing POST_NOTIFICATIONS → error.
    no_post = _GOOD_MANIFEST.replace(
        '<uses-permission\n        android:name="android.permission.POST_NOTIFICATIONS" />',
        "",
    )
    expect("missing POST_NOTIFICATIONS", check_packaged_manifest(no_post), False)

    # Exported boot receiver in the packaged manifest → error.
    exported = _GOOD_MANIFEST.replace(
        'ScheduledNotificationBootReceiver"\n            android:exported="false"',
        'ScheduledNotificationBootReceiver"\n            android:exported="true"',
    )
    expect("exported boot receiver", check_packaged_manifest(exported), False)

    # Missing scheduled receiver entirely (as if R8 stripped it) → error.
    no_receiver = re.sub(
        r"<receiver\s+android:name=\"com\.dexterous\.flutterlocalnotifications\."
        r"ScheduledNotificationReceiver\"[^/]*/>",
        "",
        _GOOD_MANIFEST,
    )
    expect("missing scheduled receiver", check_packaged_manifest(no_receiver), False)

    # Version mismatch → error.
    expect("version mismatch", check_version(_GOOD_MANIFEST, "0.0.99", "99"), False)

    # Icon resource stripped from the resource table → error.
    stripped_resources = _GOOD_AAPT2_RESOURCES.replace(
        "resource 0x7f070074 drawable/ic_stat_calee\n      () (file) res/Ry.xml type=XML\n",
        "",
    )
    expect(
        "icon resource stripped", check_packaged_icon_resource(stripped_resources), False
    )
    stripped_backing = extract_icon_backing_file(stripped_resources)
    expect(
        "icon file check fails when resource stripped",
        check_icon_file_packaged(stripped_backing, _GOOD_APKANALYZER_FILES),
        False,
    )

    # Backing file resolved but missing from the packaged file list → error.
    expect(
        "icon backing file missing from apk",
        check_icon_file_packaged("res/Ry.xml", "/AndroidManifest.xml\n/classes.dex\n"),
        False,
    )

    if failures:
        for failure in failures:
            print(f"::error::{failure}")
        print(f"SELFTEST FAILED: {len(failures)} case(s)")
        return 1
    print("SELFTEST PASSED")
    return 0


# ── Entry point ──────────────────────────────────────────────────────────────


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
        root = _repo_root()
        apk_path = argv[2] if len(argv) > 2 else os.path.join(root, DEFAULT_APK_PATH)
        errors = run_check(apk_path, root)
        if errors:
            for error in errors:
                # GitHub Actions annotation.
                print(f"::error::{error}")
            print(
                f"\nNotification release-APK check FAILED with {len(errors)} "
                "problem(s)."
            )
            return 1
        print("Notification release-APK check passed.")
        return 0
    print(f"unknown command: {command!r} (use 'check' or 'selftest')")
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
