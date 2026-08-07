# Release notes

One file per released version, named `<build_name>.md` (e.g. `0.0.30.md`) where
`<build_name>` is the `MAJOR.MINOR.PATCH` part of the `version:` line in
`pubspec.yaml`.

`scripts/release_preflight.sh` requires the file for the current version to
exist, to contain real content, and to contain no `TODO`/`TBD`/`FIXME`
placeholder. Add it in the same change that bumps `pubspec.yaml`.

The **What's New** section is the customer-facing text submitted to both the App
Store and Google Play, so write it for users, not for developers. The remaining
sections are internal release evidence.

Template:

```markdown
# <version>

## What's New

- <customer-facing change>

## Internal notes

- <anything a release operator or reviewer needs to know>

## Device qualification

- Android: <device / OS / outcome>
- iOS: <device / OS / outcome>
```
