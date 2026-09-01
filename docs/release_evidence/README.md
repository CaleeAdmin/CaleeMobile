# Release evidence

One file per released version, named `<version>.json` (e.g. `0.0.31.json`) where
`<version>` is the `MAJOR.MINOR.PATCH` part of the `version:` line in
`pubspec.yaml`.

`docs/STORE_RELEASE_CHECKLIST.md` tells the Release Operator **what to do**.
This directory is where the operator records that they **actually did it**, for
one specific build, in a form the machine can check.

## Two phases, because readiness is not one event

Some things must be true *before* a signed candidate can be built. Others can
only be honestly attested *after* it exists — you cannot qualify a build on a
physical device before that build has been produced. The file therefore has two
sections, validated at different times:

| Section | Completed | Validated by | Contains |
| --- | --- | --- | --- |
| `build_readiness` | Before dispatching a signed release workflow | `--require-build-readiness` (the signed workflows) | Listing/privacy/review-note preparation, named Release Operator and Credential Owner, Apple credential expiry dates |
| `submission_readiness` | After the candidate is distributed to Internal Testing / TestFlight and qualified on a device | `--require-store-readiness` (the operator, before uploading to a store) | The **exact candidate** that was tested (commit, CI run, release-manifest digest) with its device qualification nested inside, final listing/screenshot review against that candidate, reviewer test account verified on it, Release Approver sign-off |

`--require-store-readiness` is a **superset**: it re-validates `build_readiness`
as well, so nothing can regress between the two phases.

```
             build_readiness complete
                      ↓
   signed workflow ──▶ signed candidate + release manifest
                      ↓
   record the EXACT candidate identity (commit, run, manifest digest)
                      ↓
   Internal Testing / TestFlight ──▶ install THAT candidate
                      ↓
          physical-device qualification
                      ↓
          submission_readiness complete
                      ↓
                store submission
```

## Creating one

```bash
cp docs/release_evidence/TEMPLATE.json docs/release_evidence/0.0.31.json

# 1. Fill in `version`, `build_number` and the whole build_readiness section.
scripts/release_preflight.sh check --require-build-readiness
#    -> now the signed release workflow can be dispatched from stage/main.

# 2. After the signed run, capture the candidate identity:
scripts/generate_release_manifest.sh checksum <downloaded release manifest>

# 3. Install THAT candidate, qualify it on a device, fill in submission_readiness.
scripts/release_preflight.sh check --platform ios --require-store-readiness
#    -> now, and only now, the candidate may be uploaded for review.
```

Commit the evidence to the branch being released, so it lands on `stage`/`main`
with the code it describes.

## What is validated

| Field | Rule |
| --- | --- |
| `schema` | must be `calee-mobile-release-evidence/4`. `/3` is accepted **only** for 0.0.32 and 0.0.33 — see [Schema 4](#schema-4-the-canonical-privacy-policy-url) |
| `version`, `build_number` | must match `pubspec.yaml` exactly — evidence from a previous release cannot be reused |
| `*.reviewed_at` | ISO `YYYY-MM-DD`, not in the future |
| `build_readiness.release_operator` | non-empty, and **no placeholder text** |
| `build_readiness.credential_owner_android` / `_apple` | required for the platform being released, same placeholder rule |
| `build_readiness.checks.*` | every required key must be the literal boolean `true`. `false`, a missing key, or a string such as `"TODO"` fails |
| `build_readiness.privacy_policy_url` | schema 4: must be exactly `https://calee.com.au/privacy/` |
| `build_readiness.apple_certificate_expiry`, `apple_provisioning_profile_expiry` | iOS only: ISO dates that must still be **in the future** at build time |
| `submission_readiness.release_approver` | non-empty, no placeholder text |
| `submission_readiness.checks.*` | as above |
| `submission_readiness.<platform>_candidate.git_sha` | 40-character hex Git SHA, no placeholder |
| `submission_readiness.<platform>_candidate.workflow_run_id` | numeric GitHub Actions run id, no placeholder |
| `submission_readiness.<platform>_candidate.workflow_run_attempt` | numeric, ≥ 1, no placeholder |
| `submission_readiness.<platform>_candidate.release_manifest_sha256` | 64-character hex SHA-256 of that run's release manifest |
| `submission_readiness.<platform>_candidate.device_qualification` | `device`, `os_version` non-placeholder; `outcome` must be `pass`; `build_number` must match the release |
| Android vs iOS candidates | must share a `git_sha`; must **not** share a `release_manifest_sha256` or a `workflow_run_id` (they come from different workflow runs) |

Required `checks` keys are platform-scoped: the shared set always applies; the
`android_*` / `google_play_*` keys apply to Android releases and the `ios_*` /
`apple_*` keys to iOS releases. A file carrying all of them satisfies both.

### Schema 4: the canonical privacy-policy URL

Schema 4 adds one required field, `build_readiness.privacy_policy_url`, pinned
to the canonical Calee Privacy Policy at `https://calee.com.au/privacy/`
(CaleeAdmin/calee-hub-web#107).

**Why a new field rather than another boolean.** The existing
`privacy_policy_url_reviewed` check records only that somebody reviewed *a*
privacy policy URL. It cannot tell the canonical policy from the retired
`https://portal.calee.com.au/privacy` one — which is exactly the ambiguity the
migration exists to remove. The store listings must carry the canonical URL, so
the evidence has to name it.

**Backwards compatibility, and its limit.** Schema `/3` is still accepted, but
only for **0.0.32 and 0.0.33** — the releases that actually shipped under it.
Their evidence is the historical record of what those operators reviewed at the
time; rewriting it to name a URL that did not yet exist would be falsifying
release evidence, so it is left alone and preflight says so explicitly in its
output. Every other version, including every future release, must use schema 4.
That deliberately closes the obvious loophole: a new release cannot skip the
requirement by simply not upgrading its evidence file.

**What this does and does not prove.** A green preflight means an operator
*recorded* the canonical URL. It does not mean either store listing was
changed — that is a manual update in App Store Connect and the Google Play
Console. See [../STORE_RELEASE_CHECKLIST.md](../STORE_RELEASE_CHECKLIST.md).

### Why a build number is not enough

**"Same build number" does not prove "same signed candidate."** `pubspec.yaml`
carries the build number, so two signed workflow runs from two different commits
can legitimately produce artifacts stamped with the same one. If qualification
were recorded against a build number alone, an operator could test one candidate
and submit another and no check would notice.

Each platform therefore records the **exact candidate** it tested:

```json
"android_candidate": {
  "git_sha": "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678",
  "workflow_run_id": "31230013473",
  "workflow_run_attempt": "1",
  "release_manifest_sha256": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
  "device_qualification": {
    "device": "Pixel 8",
    "os_version": "Android 16",
    "build_number": "31",
    "outcome": "pass"
  }
}
```

The device qualification is **nested inside** the candidate, so it cannot be
detached from the artifact it describes. Android and iOS are separate blocks
because they are built by different workflows, from different runs, with
different manifests — they must agree on the commit and must not share a run id
or a manifest digest.

### Where the operator gets these values

Run the helper against the release manifest downloaded from the signed workflow
run; it prints every value and a ready-to-paste block:

```bash
scripts/generate_release_manifest.sh checksum ~/Downloads/release-manifest-android.json
```

The signed workflows also print the same block in their
**"Print candidate identity for release evidence"** step, so it can be copied
straight out of the run log. Both sources agree because both derive from the same
manifest.

| Value | Where it comes from |
| --- | --- |
| `git_sha` | the manifest's `source.git_sha`, i.e. the commit the workflow built |
| `workflow_run_id` / `workflow_run_attempt` | the manifest's `ci.run_id` / `ci.run_attempt`; also the run URL |
| `release_manifest_sha256` | SHA-256 of the manifest file itself, printed by the helper |

Optionally prove the recorded identity really describes the manifest you hold:

```bash
scripts/release_preflight.sh check --platform android --require-store-readiness \
  --candidate-manifest android=~/Downloads/release-manifest-android.json
```

That compares the digest **and** the manifest's commit, run id, version and build
number against the evidence. It is entirely local — preflight never downloads an
artifact.

### Placeholder rejection

Any of these, in any required text field, fails validation:

`REPLACE`, `REPLACE-WITH-VERSION`, `REPLACE — the person performing this release`
(and every other `REPLACE …` marker in `TEMPLATE.json`), `TODO`, `TBD`, `TBC`,
`FIXME`, `XXX`, `PLACEHOLDER`, `CHANGEME`, `UNKNOWN`, `UNCONFIRMED`,
`NAME HERE`, `Operator decision required`, `REQUIRED — NOT SUPPLIED`,
`to be recorded/confirmed/decided/supplied`, and the unfilled date `YYYY-MM-DD`.

Matching is word-bounded, so ordinary values are unaffected — a person named
"Sam Replaced-Jones" or a device recorded as "Pixel 8 Pro (replacement unit)"
passes. The selftest asserts both directions, using the template's exact strings.

**Copying `TEMPLATE.json` and editing only the version/build number cannot
pass.** That is an explicit test case.

## Rules

- **Never** record passwords, API keys, certificate material, or the password of
  the store reviewer test account here. Record only that the account was
  *verified*; the credentials themselves belong in the store console and the
  team's password manager.
- Do not pre-tick items, and do not fill in `submission_readiness` before the
  candidate has actually been installed and exercised. A `true` here is a
  statement by a named person about a specific build.
- Do not copy a previous version's file and bump the version — the checks exist
  because listings, disclosures and screenshots drift from the product.
