#!/usr/bin/env bash
#
# Read the (non-secret) signing certificate identity out of a signed APK.
#
# The release manifest records WHO signed an artifact — the certificate's
# public distinguished name and SHA-256 fingerprint — so anything downloaded
# from a run can be tied back to the upload key. That identity comes from
# `apksigner verify --print-certs`, whose certificate LABELS differ between
# build-tools releases:
#
#   Signer #1 certificate DN: CN=...                # historic label
#   Signer #1 certificate SHA-256 digest: <64 hex>
#
#   V2 Signer: certificate DN: CN=...               # per-scheme label, newer
#   V2 Signer: certificate SHA-256 digest: <64 hex> # build-tools
#
# The release workflow used to grep for a hardcoded "Signer #1 " prefix. That
# prefix silently stopped matching when the GitHub runner image picked up newer
# build-tools, and the signed build failed after a ~19 minute compile with
# "Could not read the signing certificate identity". This parser keys off the
# STABLE part of the line ("certificate DN:" / "certificate SHA-256 digest:")
# and treats whatever precedes it as the signer label, so both spellings — and
# any future scheme label — work.
#
# Usage:
#   scripts/read_apk_signing_identity.sh selftest
#   scripts/read_apk_signing_identity.sh read APK
#   scripts/read_apk_signing_identity.sh parse [FILE]
#
# read   verifies APK with apksigner and prints the signing identity:
#          CN=Example, O=Example Pty Ltd (certificate SHA-256 <64 hex chars>)
#        apksigner is taken from $APKSIGNER, else the highest-versioned
#        build-tools under $ANDROID_HOME / $ANDROID_SDK_ROOT, else $PATH.
#
# parse  reads apksigner output from FILE (or stdin) and prints the same
#        identity. Used by the selftest, and for diagnosing a build by hand.
#
# When an APK carries more than one DISTINCT signing certificate (key
# rotation), every distinct identity is printed on one line joined by "; ", so
# the manifest can never quietly record just one of the signers. Certificates
# repeated across signature schemes (v1/v2/v3 signed with the same key) collapse
# to a single identity. Source-stamp certificates are not signing identities and
# are ignored.
#
# FAILS CLOSED: an unverifiable APK, no signer certificate, a signer missing its
# DN or SHA-256 digest, or a malformed digest is an error — never an empty or
# partial identity.
#
# SECURITY: only public certificate information is read or printed. Keystores,
# passwords and key material are never touched.

set -euo pipefail

err() {
  printf '%s\n' "$*" >&2
}

usage() {
  sed -n '2,50p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# --- parsing ----------------------------------------------------------------

# cmd_parse [FILE]
#
# Prints the signing identity found in apksigner --print-certs output.
cmd_parse() {
  local input="${1:--}"

  local tmp_file
  tmp_file="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp_file'" RETURN

  if [[ "$input" == "-" ]]; then
    cat > "$tmp_file"
  else
    if [[ ! -f "$input" ]]; then
      err "apksigner output file not found: $input"
      return 1
    fi
    cat "$input" > "$tmp_file"
  fi

  python3 - "$tmp_file" <<'PY'
import re
import sys

DN_MARKER = " certificate DN: "
SHA_MARKER = " certificate SHA-256 digest: "
HEX64 = re.compile(r"^[0-9a-fA-F]{64}$")

with open(sys.argv[1], encoding="utf-8", errors="replace") as handle:
    text = handle.read()

# Certificates are grouped by their label ("Signer #1", "V2 Signer:", ...)
# because apksigner prints the DN and every digest of one certificate on
# consecutive lines sharing that label. Insertion order is preserved so the
# emitted identity order matches the tool's own output.
order = []
signers = {}


def slot(label):
    if label not in signers:
        signers[label] = {}
        order.append(label)
    return signers[label]


for raw_line in text.splitlines():
    line = raw_line.rstrip()
    for marker, key in ((DN_MARKER, "dn"), (SHA_MARKER, "sha256")):
        index = line.find(marker)
        # index <= 0 means there is no label in front of the marker, so the
        # line is not a certificate line this parser understands.
        if index <= 0:
            continue
        # Only the first value per label is kept: apksigner prints each
        # certificate once, and a duplicate would mean unexpected output.
        slot(line[:index].strip()).setdefault(key, line[index + len(marker):].strip())
        break

# A source stamp is a separate, Play-issued certificate that does not identify
# who signed the APK, so it must never be recorded as the signing identity.
signer_labels = [label for label in order if "source stamp" not in label.lower()]

if not signer_labels:
    print(
        "No signer certificate found in apksigner output. Expected a line like "
        "'Signer #1 certificate DN: ...' or 'V2 Signer: certificate DN: ...'.",
        file=sys.stderr,
    )
    sys.exit(1)

problems = []
identities = []

for label in signer_labels:
    info = signers[label]
    dn = info.get("dn", "")
    sha256 = info.get("sha256", "")

    if not dn:
        problems.append("%s: no certificate DN" % label)
    if not sha256:
        problems.append("%s: no certificate SHA-256 digest" % label)
    elif not HEX64.match(sha256):
        problems.append("%s: malformed certificate SHA-256 digest %r" % (label, sha256))

    if dn and sha256 and HEX64.match(sha256):
        identity = "%s (certificate SHA-256 %s)" % (dn, sha256.lower())
        if identity not in identities:
            identities.append(identity)

if problems:
    for problem in problems:
        print("Incomplete signing certificate: %s" % problem, file=sys.stderr)
    sys.exit(1)

print("; ".join(identities))
PY
}

# --- apksigner lookup -------------------------------------------------------

resolve_apksigner() {
  if [[ -n "${APKSIGNER:-}" ]]; then
    if [[ ! -x "$APKSIGNER" ]]; then
      err "APKSIGNER is set but not executable: $APKSIGNER"
      return 1
    fi
    printf '%s\n' "$APKSIGNER"
    return 0
  fi

  local sdk_root version candidate
  for sdk_root in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}"; do
    [[ -n "$sdk_root" && -d "$sdk_root/build-tools" ]] || continue
    # Newest build-tools first, but keep looking if the newest package has no
    # apksigner (a partially installed SDK must not defeat the lookup).
    while IFS= read -r version; do
      candidate="$sdk_root/build-tools/$version/apksigner"
      if [[ -x "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done < <(ls -1 "$sdk_root/build-tools" | sort -Vr)
  done

  if command -v apksigner >/dev/null 2>&1; then
    command -v apksigner
    return 0
  fi

  err "apksigner not found: set \$APKSIGNER, install Android build-tools under \$ANDROID_HOME, or put apksigner on \$PATH"
  return 1
}

# cmd_read APK
cmd_read() {
  local apk="${1:-}"
  if [[ -z "$apk" ]]; then
    err "read requires an APK path"
    usage >&2
    return 2
  fi
  if [[ ! -f "$apk" ]]; then
    err "APK not found: $apk"
    return 1
  fi

  local apksigner_bin
  apksigner_bin="$(resolve_apksigner)" || return 1

  local certs status=0
  certs="$("$apksigner_bin" verify --print-certs "$apk")" || status=$?
  if (( status != 0 )); then
    err "apksigner could not verify $apk (exit $status)"
    return 1
  fi

  printf '%s\n' "$certs" | cmd_parse -
}

# --- selftest ---------------------------------------------------------------
#
# Proves the parser reads both apksigner label spellings — the historic
# "Signer #1" and the per-scheme "V2 Signer:" that broke release build #64 —
# and that anything it cannot fully understand fails closed instead of
# producing an empty identity. Runs entirely on recorded apksigner output, so
# it needs no Android SDK and guards the parser on every PR.

cmd_selftest() {
  local self_path
  self_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp_dir'" RETURN

  local failures=0
  local sha_a="992e6a29b2d32e639dccefceb22ba23d07c960b0c49e43620112fddd2d887bc6"
  local sha_b="1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a"

  # expect_identity <name> <fixture-file> <expected-output>
  expect_identity() {
    local name="$1" fixture="$2" expected="$3"
    local actual status=0
    actual="$(bash "$self_path" parse "$fixture" 2>/dev/null)" || status=$?
    if (( status == 0 )) && [[ "$actual" == "$expected" ]]; then
      echo "  PASS: $name"
    else
      echo "  FAIL: $name (exit $status)"
      echo "    expected: $expected"
      echo "    actual:   $actual"
      failures=$((failures + 1))
    fi
  }

  # expect_failure <name> <args...>
  expect_failure() {
    local name="$1"
    shift
    local status=0
    bash "$self_path" "$@" >/dev/null 2>&1 || status=$?
    if (( status != 0 )); then
      echo "  PASS: $name (exit $status)"
    else
      echo "  FAIL: $name (expected non-zero, got 0)"
      failures=$((failures + 1))
    fi
  }

  echo "selftest: every apksigner certificate label must be understood"

  # Historic label, still emitted by older build-tools.
  cat > "$tmp_dir/signer-hash.txt" <<EOF
Signer #1 certificate DN: CN=Example, O=Example Pty Ltd
Signer #1 certificate SHA-256 digest: $sha_a
Signer #1 certificate SHA-1 digest: aa0e7f3fc03d05a6da63f48925f9b50a5e3abc92
Signer #1 certificate MD5 digest: b22e987950a9f68b0c8388848364cb5b
EOF
  expect_identity signer-number "$tmp_dir/signer-hash.txt" \
    "CN=Example, O=Example Pty Ltd (certificate SHA-256 $sha_a)"

  # Per-scheme label — the exact shape that failed the signed release build.
  cat > "$tmp_dir/v2-signer.txt" <<EOF
V2 Signer: certificate DN: C=AU, ST=WA, L=Perth, O=Calee, OU=Engineering, CN=My Calee Pty Ltd
V2 Signer: certificate SHA-256 digest: $sha_a
V2 Signer: certificate SHA-1 digest: aa0e7f3fc03d05a6da63f48925f9b50a5e3abc92
V2 Signer: certificate MD5 digest: b22e987950a9f68b0c8388848364cb5b
EOF
  expect_identity v2-scheme-label "$tmp_dir/v2-signer.txt" \
    "C=AU, ST=WA, L=Perth, O=Calee, OU=Engineering, CN=My Calee Pty Ltd (certificate SHA-256 $sha_a)"

  # One key, several schemes: one identity, not three.
  cat > "$tmp_dir/v1-v2-v3.txt" <<EOF
V1 Signer: certificate DN: CN=Example, O=Example Pty Ltd
V1 Signer: certificate SHA-256 digest: $sha_a
V2 Signer: certificate DN: CN=Example, O=Example Pty Ltd
V2 Signer: certificate SHA-256 digest: $sha_a
V3 Signer: certificate DN: CN=Example, O=Example Pty Ltd
V3 Signer: certificate SHA-256 digest: $sha_a
EOF
  expect_identity same-cert-across-schemes "$tmp_dir/v1-v2-v3.txt" \
    "CN=Example, O=Example Pty Ltd (certificate SHA-256 $sha_a)"

  # Rotated keys: both identities must be recorded, never just the first.
  cat > "$tmp_dir/rotated.txt" <<EOF
V3 Signer: certificate DN: CN=Old Key, O=Example Pty Ltd
V3 Signer: certificate SHA-256 digest: $sha_a
V3.1 Signer: certificate DN: CN=New Key, O=Example Pty Ltd
V3.1 Signer: certificate SHA-256 digest: $sha_b
EOF
  expect_identity rotated-keys "$tmp_dir/rotated.txt" \
    "CN=Old Key, O=Example Pty Ltd (certificate SHA-256 $sha_a); CN=New Key, O=Example Pty Ltd (certificate SHA-256 $sha_b)"

  # An uppercase digest is normalised so manifests compare byte for byte.
  local sha_a_upper
  sha_a_upper="$(printf '%s' "$sha_a" | tr 'a-f' 'A-F')"
  cat > "$tmp_dir/uppercase.txt" <<EOF
Signer #1 certificate DN: CN=Example, O=Example Pty Ltd
Signer #1 certificate SHA-256 digest: $sha_a_upper
EOF
  expect_identity uppercase-digest-normalised "$tmp_dir/uppercase.txt" \
    "CN=Example, O=Example Pty Ltd (certificate SHA-256 $sha_a)"

  # Warnings and unrelated output around the certificate block are ignored.
  cat > "$tmp_dir/noisy.txt" <<EOF
WARNING: META-INF/services/foo not protected by signature.
Signer #1 certificate DN: CN=Example, O=Example Pty Ltd
Signer #1 certificate SHA-256 digest: $sha_a
WARNING: This APK is not signed with the v4 scheme.
EOF
  expect_identity surrounding-warnings-ignored "$tmp_dir/noisy.txt" \
    "CN=Example, O=Example Pty Ltd (certificate SHA-256 $sha_a)"

  echo "selftest: a source stamp is not a signing identity"
  cat > "$tmp_dir/source-stamp.txt" <<EOF
Signer #1 certificate DN: CN=Example, O=Example Pty Ltd
Signer #1 certificate SHA-256 digest: $sha_a
Source Stamp Signer certificate DN: CN=Play Source Stamp
Source Stamp Signer certificate SHA-256 digest: $sha_b
EOF
  expect_identity source-stamp-excluded "$tmp_dir/source-stamp.txt" \
    "CN=Example, O=Example Pty Ltd (certificate SHA-256 $sha_a)"

  echo "selftest: unreadable or partial output must fail closed"

  # Verified, but no certificate block at all (the failure this script exists
  # to turn into a loud, specific error rather than an empty identity).
  printf 'Verifies\nVerified using v2 scheme (APK Signature Scheme v2): true\n' \
    > "$tmp_dir/no-certs.txt"
  expect_failure no-certificate-lines parse "$tmp_dir/no-certs.txt"

  printf 'Signer #1 certificate DN: CN=Example\n' > "$tmp_dir/dn-only.txt"
  expect_failure dn-without-digest parse "$tmp_dir/dn-only.txt"

  printf 'Signer #1 certificate SHA-256 digest: %s\n' "$sha_a" > "$tmp_dir/digest-only.txt"
  expect_failure digest-without-dn parse "$tmp_dir/digest-only.txt"

  cat > "$tmp_dir/empty-dn.txt" <<EOF
Signer #1 certificate DN:
Signer #1 certificate SHA-256 digest: $sha_a
EOF
  expect_failure empty-dn parse "$tmp_dir/empty-dn.txt"

  cat > "$tmp_dir/short-digest.txt" <<EOF
Signer #1 certificate DN: CN=Example
Signer #1 certificate SHA-256 digest: deadbeef
EOF
  expect_failure malformed-digest parse "$tmp_dir/short-digest.txt"

  cat > "$tmp_dir/stamp-only.txt" <<EOF
Source Stamp Signer certificate DN: CN=Play Source Stamp
Source Stamp Signer certificate SHA-256 digest: $sha_b
EOF
  expect_failure source-stamp-only parse "$tmp_dir/stamp-only.txt"

  # A label-less line is not a certificate line, so it cannot be mistaken for one.
  printf ' certificate DN: CN=Example\n certificate SHA-256 digest: %s\n' "$sha_a" \
    > "$tmp_dir/no-label.txt"
  expect_failure unlabelled-certificate-line parse "$tmp_dir/no-label.txt"

  : > "$tmp_dir/empty.txt"
  expect_failure empty-output parse "$tmp_dir/empty.txt"
  expect_failure missing-file parse "$tmp_dir/does-not-exist.txt"
  expect_failure missing-apk read "$tmp_dir/does-not-exist.apk"
  expect_failure no-arguments

  if (( failures > 0 )); then
    err "selftest FAILED with $failures failure(s)."
    return 1
  fi

  echo "selftest passed."
}

case "${1:-}" in
  selftest)
    cmd_selftest
    ;;
  parse)
    shift
    cmd_parse "$@"
    ;;
  read)
    shift
    cmd_read "$@"
    ;;
  -h|--help|help)
    usage
    ;;
  "")
    err "A subcommand is required."
    usage >&2
    exit 2
    ;;
  *)
    err "Unknown subcommand: $1"
    usage >&2
    exit 2
    ;;
esac
