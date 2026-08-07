# Release evidence

One file per released version, named `<version>.json` (e.g. `0.0.30.json`) where
`<version>` is the `MAJOR.MINOR.PATCH` part of the `version:` line in
`pubspec.yaml`.

`docs/STORE_RELEASE_CHECKLIST.md` tells the Release Operator **what to do**.
This directory is where the operator records that they **actually did it**, for
one specific build, in a form the machine can check.

The signed Android and iOS release workflows run

```bash
scripts/release_preflight.sh check --platform <platform> --require-store-readiness ...
```

which **fails the release** unless the evidence file for the version being built
exists and is complete. Ordinary pull-request CI does not require it, so day-to-day
development is unaffected.

## Creating one

```bash
cp docs/release_evidence/TEMPLATE.json docs/release_evidence/0.0.31.json
# edit it, then verify locally before dispatching a signed build:
scripts/release_preflight.sh check --require-store-readiness
```

Commit the completed evidence to the branch being released, so it lands on
`stage`/`main` with the code it describes.

## What is validated

| Field | Rule |
| --- | --- |
| `schema` | must be `calee-mobile-release-evidence/1` |
| `version`, `build_number` | must match `pubspec.yaml` exactly — evidence from a previous release cannot be reused |
| `reviewed_at` | ISO `YYYY-MM-DD`, not in the future |
| `release_approver`, `release_operator` | non-empty, and **no placeholder text** (`TODO`, `TBD`, `UNKNOWN`, `REPLACE …`, etc.) |
| `credential_owner_android` / `credential_owner_apple` | required for the platform being released, same placeholder rule |
| `checks.*` | every required key must be the literal boolean `true`. `false`, a missing key, or a string such as `"TODO"` fails |
| `android_device_qualification` / `ios_device_qualification` | `device`, `os_version` non-placeholder; `outcome` must be `pass`; `build_number` must match the build being released |
| `apple_certificate_expiry`, `apple_provisioning_profile_expiry` | ISO dates that must still be **in the future** at build time |

Required `checks` keys are platform-scoped: the shared set always applies; the
`android_*` / `google_play_*` keys apply to Android releases and the `ios_*` /
`apple_*` keys to iOS releases. A file that carries all of them satisfies both.

## Rules

- **Never** record passwords, API keys, certificate material, or the password of
  the store reviewer test account here. Record only that the account was
  *verified*; the credentials themselves belong in the store console and the
  team's password manager.
- Do not pre-tick items. A `true` here is a statement by a named person that the
  item was checked against this build.
- Do not copy a previous version's file and bump the version — the checks exist
  because listings, disclosures and screenshots drift from the product.
