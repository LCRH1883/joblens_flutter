# Repository Guidelines

## Project Structure & Module Organization
This is a Flutter mobile app targeting Android and iOS.

- `lib/main.dart`: app bootstrap, DI wiring, and startup initialization.
- `lib/src/app/`: app shell and global state store.
- `lib/src/core/`: shared infrastructure (`db/`, `models/`, `storage/`, `sync/`).
- `lib/src/features/`: feature modules (`camera`, `gallery`, `projects`, `sync`, `settings`, `importing`).
- `test/`: unit/widget tests (`*_test.dart`).
- `android/`, `ios/`: platform-specific configuration and permissions.

Prefer adding new functionality under `lib/src/features/<feature_name>/` and keep cross-feature utilities in `lib/src/core/`.

## Build, Test, and Development Commands
Use the local Flutter binary configured for this repo:

- `/Users/lcrh/Tools/flutter/bin/flutter pub get` — install dependencies.
- `/Users/lcrh/Tools/flutter/bin/flutter run` — run on connected device/simulator.
- `/Users/lcrh/Tools/flutter/bin/flutter analyze` — static analysis and lint checks.
- `/Users/lcrh/Tools/flutter/bin/flutter test` — run test suite.
- `/Users/lcrh/Tools/flutter/bin/dart format lib test` — format Dart sources.

## Coding Style & Naming Conventions
- Follow Dart style with **2-space indentation**.
- File names: `snake_case.dart`.
- Types/classes/enums: `PascalCase`.
- Variables/methods/fields: `lowerCamelCase`.
- Keep widgets and services focused; avoid large, multi-purpose classes.
- Run `dart format` and `flutter analyze` before opening a PR.

## Testing Guidelines
- Framework: `flutter_test`.
- Place tests under `test/` and name files `*_test.dart`.
- Add tests for new business logic (sync, DB, storage) and critical UI flows.
- Minimum PR expectation: tests pass locally and no analyzer warnings/errors.

## Commit & Pull Request Guidelines
Git history is not available in this workspace, so use this standard:

- Commit format: `type(scope): summary` (e.g., `feat(sync): add box upload adapter`).
- Keep commits focused and logically grouped.
- PRs should include:
  - What changed and why
  - Linked issue/task (if any)
  - Test evidence (`flutter analyze`, `flutter test`)
  - Screenshots/video for UI changes

## Security & Configuration Tips
- Never commit access tokens, app passwords, or secrets.
- Store provider credentials via secure storage only.
- Validate cloud sync changes against failure paths (401, 403, network timeout).
