# CaleeMobile — Developer & AI Instructions

## Dart Formatting (required before every commit)

The CI pipeline enforces `dart format` with `--set-exit-if-changed`. Any unformatted file will fail the **Check formatting** step in `.github/workflows/flutter-ci.yml`.

**Always run before committing:**

```bash
dart format lib test
```

This applies to both human developers and AI assistants (Claude, Copilot, etc.) — format every Dart file you touch before staging it.

## CI Pipeline

`.github/workflows/flutter-ci.yml` runs on every push and pull request:

1. **Check formatting** — `dart format --set-exit-if-changed lib test`
2. **Analyze** — `flutter analyze --fatal-infos`
3. **Test** — `flutter test` (timezone: `Australia/Perth`)

All three steps must pass. Do not disable or skip the formatting step.

## Workflow for AI-assisted changes

1. Make your Dart changes.
2. Run `dart format lib test` to reformat.
3. Run `flutter analyze --fatal-infos` and fix any warnings.
4. Run `flutter test` and confirm all tests pass.
5. Commit and push.

Do not make logic changes unless they are required to fix an `analyze` or `test` failure.
