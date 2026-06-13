# CaleeMobile — Developer & AI Guide

## Formatting (mandatory before every commit)

The CI pipeline enforces Dart formatting via `dart format --set-exit-if-changed lib test` (see `.github/workflows/flutter-ci.yml`). Any unformatted file will fail CI.

**Always run the formatter before staging or committing:**

```bash
dart format lib test
```

If you only want to check without writing changes:

```bash
dart format --output=none lib test
```

For AI assistants / Claude: after any edit to a `.dart` file, run `dart format lib test` before calling `git add` or `git commit`. Do not skip this step even for single-line changes — the formatter may reflow surrounding code.

## CI checks (in order)

1. `dart format --set-exit-if-changed lib test` — formatting
2. `flutter analyze --fatal-infos` — static analysis (infos are fatal)
3. `flutter test` — unit tests (timezone set to `Australia/Perth`)

All three must pass. Fix formatting first; then address any analyzer warnings before changing logic.

## General rules

- Do not make logic changes unless required by `flutter analyze` or `flutter test` failures.
- Keep the formatting step in `.github/workflows/flutter-ci.yml` as-is.
