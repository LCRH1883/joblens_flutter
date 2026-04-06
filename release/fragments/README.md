# Release Fragments

Use this folder to record user-facing release notes as features and fixes are added.

Workflow:

1. Create a fragment when a feature, major change, or major bug fix lands.
2. Mark whether it applies to `android`, `ios`, or `both`.
3. When preparing a release, run `scripts/prepare_release_notes.sh <version>`.
4. The script prepends a new section to:
   - `release/android/CHANGELOG.md`
   - `release/ios/CHANGELOG.md`
5. After the release notes are generated, move or delete the used fragments.

Expected fragment format:

```text
platforms=both
type=feature
summary=Added account password reset flow.
details=- Added forgot-password email flow.\n- Added in-app password reset screen.
```

Allowed values:

- `platforms=android`
- `platforms=ios`
- `platforms=both`

Suggested types:

- `feature`
- `change`
- `bugfix`
