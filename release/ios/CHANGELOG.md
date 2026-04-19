# Joblens iOS Changelog

This file tracks user-facing iOS release history.

Rules:

- include new features
- include major feature changes
- include major bug fixes
- omit minor internal refactors unless they changed release behavior
- keep entries newest first

## v0.2.1

- Improved sign-in, session restore, and forced sign-out handling so account state is more stable across launches and device changes.
- Improved sync reliability for provider changes, remote asset downloads, and project media hydration.
- Reduced stale or oversized thumbnail usage so project and gallery views refresh more consistently.
- Improved camera availability and launch handling so capture flows recover more reliably.

## v0.2.0

- Added a compact floating camera button inside project views so you can capture directly into the current project.
- Added an Appearance setting to show or hide the project camera button.
- Replaced the multi-select bottom action bar with a compact floating action pill and improved its contrast in light and dark themes.
- Project-launched camera sessions now persist the selected project as the active camera target.
- Fixed iOS native camera close handling so project-launched camera sessions dismiss more reliably.

## v0.1.4

- Gallery now only shows photos that are stored on this device, while Inbox and Projects still show cloud-only photos.
- Fixed cloud and local photo state handling so downloaded and restored photos keep the correct synced status.
- Fixed moved photos during ongoing imports so they stay in the selected project after sync completes.

## v0.1.3

- Fixed an issue where recreating a deleted project with the same name could fail.

## v0.1.2

- Fixed a sync bug that could re-upload imported photos instead of recognizing existing imported media correctly.

## v0.1.1

- Stability update focused on sync reliability and project ordering consistency.
  - Fixed remote media downloads to use the correct public backend media host.
  - Fixed project ordering so refreshes no longer reshuffle the list.
  - Fixed synced asset moves so remote items move instead of being re-uploaded.
  - Hardened first-device and fresh-device sync so existing cloud projects and assets bootstrap correctly.

## v0.1.0 Alpha

- First iOS alpha release.
- Available features:
  - in-app camera capture with rapid multi-shot support
  - device photo import into the private Joblens library
  - gallery timeline for browsing local and synced job photos
  - project creation, editing, notes, start dates, and stable sorting
  - Inbox project pinned to the top of project views
  - local-first photo moves between projects with background sync
  - Joblens account sign in, sign up, email confirmation, password reset, and session restore
  - cloud sync through the Joblens backend using the user's own cloud provider account
  - cross-device project discovery and remote photo download on a new device
  - light mode, dark mode, and system theme support
- Major changes and fixes:
  - fixed remote media download paths to use the public backend media host
  - fixed project ordering so refreshes no longer reshuffle the list
  - fixed synced asset moves so they perform remote moves instead of re-uploading
  - hardened fresh-device sync so existing cloud projects and assets bootstrap correctly
