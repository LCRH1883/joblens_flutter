# Joblens User Guide

This guide explains how to use Joblens on iPhone and Android.

Joblens is a photo capture and organization app built for job-site workflows. You can use it locally on one device, or sign in and sync your library through your own connected cloud storage.

## What Joblens does

- Capture photos from inside Joblens
- Import photos from your phone library
- Organize photos into projects
- Add notes to projects
- Sign in and sync through your own cloud storage
- Keep using the app even when you are offline

## Main navigation

The bottom navigation has four sections:

- `Camera`
- `Gallery`
- `Projects`
- `Settings`

## Getting started

You can start using Joblens immediately for local photo capture and organization.

To enable cloud sync:

1. Open `Settings`
2. Open `Account`
3. Sign in or create a Joblens account
4. Go back to `Settings`
5. Open `Cloud sync`
6. Connect a cloud provider

Cloud sync is optional. If you are offline or not signed in, you can still capture photos, organize them into projects, and edit notes on the device.

## Camera

Open `Camera` from the bottom navigation to capture photos directly in Joblens.

### How camera capture works

On supported phones, Joblens opens a native camera session for capture. If native capture is unavailable, Joblens falls back to the in-app camera automatically.

Captured photos are added to Joblens right away. Cloud sync happens afterward in the background.

### Camera features

- Open camera directly from the bottom navigation
- Capture multiple photos without leaving the camera flow
- Back out of the camera and return to the app
- Flash mode control
- Front or rear lens switching when supported
- Zoom presets
- `Single` capture mode
- `Rapid` capture mode for faster multi-shot work

### Capture targets

Joblens can save captured photos into different project targets.

Available target modes are:

- `Inbox`
- `Last used`
- a specific project

This lets you keep quick captures going to `Inbox` or send them straight into the project you are working on.

## Gallery

Open `Gallery` to view your full Joblens photo library.

### Gallery features

- Photos grouped by day
- Pull to refresh
- Tap a photo to open the full-screen viewer
- Select multiple photos
- Move photos to another project
- Copy photos back to the phone gallery
- Delete selected photos

### Full-screen photo viewer

When you open a photo:

- Swipe left or right to move through photos
- Pinch to zoom
- Joblens uses the local file when available
- If the photo is cloud-only, Joblens loads it through the sync backend

## Importing from your phone library

You can import existing photos from your phone into Joblens.

There are two ways to reach import:

- `Settings > Storage > Import photos`
- import flows opened from the library import screen

### Import behavior

In `Settings > Storage`, you can choose how imports work:

- `Move`
  - imports the photo into Joblens
  - removes the original from the phone after import
- `Copy`
  - imports the photo into Joblens
  - keeps the original in the phone library

### Import flow

1. Open the import screen
2. Grant photo-library permission if prompted
3. Select one or more photos
4. Tap `Import`

Imported photos appear in Joblens immediately. Sync happens afterward in the background.

## Projects

Open `Projects` to manage your folders and project-specific photo groups.

### Project list features

- Create a new project
- Edit project details
- Delete projects except `Inbox`
- Sort projects by:
  - `Name`
  - `Start date`
- `Inbox` always stays at the top

Each project card can show:

- project name
- photo count
- start date
- note preview
- latest project thumbnail

### Creating a project

When creating a project, you can set:

- project name
- optional start date

### Editing a project

Project editing lets you update:

- project name
- start date

`Inbox` is the default catch-all project and cannot be deleted.

## Project detail view

Open a project to view only the photos in that project.

### Project detail features

- Grid of photos in the project
- Multi-select
- Move selected photos to another project
- Copy selected photos to the phone gallery
- Delete selected photos
- Edit project notes

If a project has no photos yet, Joblens shows an empty-state message.

## Project notes

Each project can have notes.

Notes are edited from the project detail screen.

Notes are useful for:

- job details
- room or location notes
- work status
- reminders
- documentation tied to the project

## Account

Open `Settings > Account` to manage your Joblens account.

### Account features

- See the current signed-in email
- Sign in
- Sign out
- Change email
- Delete account

### Create account

To create an account:

1. Open `Settings > Account`
2. Tap `Sign in`
3. Switch to `Create account`
4. Enter email and password
5. Confirm your email from the link sent to your inbox

### Sign in

To sign in:

1. Open `Settings > Account`
2. Tap `Sign in`
3. Enter email and password

### Confirm email

If email confirmation is enabled, Joblens shows a confirmation state after sign-up.

From there, you can:

- resend the confirmation email
- go back to sign in

If you open the email link on your phone, the app should return directly to Joblens.

If you open the confirmation link on a computer, the backend confirmation page should guide you instead of sending you into the app.

### Forgot password

From the sign-in screen:

1. Tap `Forgot password?`
2. Enter the account email
3. Open the reset email
4. Return to Joblens
5. Set a new password

### Delete account

Deleting your account removes your Joblens account and backend data.

It does not delete files, folders, or notes already stored in your cloud drive.

## Cloud sync

Open `Settings > Cloud sync` to manage provider connections and background sync.

### What cloud sync does

Cloud sync connects your Joblens account to your own cloud storage provider. Joblens then uses the backend to coordinate uploads, downloads, project discovery, and cross-device synchronization.

### Supported providers

The app is built to support:

- Google Drive
- OneDrive
- Dropbox
- Box
- Nextcloud

### Sync page features

- See whether you are signed in
- See the active connected cloud account
- Connect a provider
- Disconnect a provider
- `Rescan cloud`
- `Run sync now`
- `Retry failed`
- Open `Sync Activity`

### Provider connection flow

For Google Drive, OneDrive, Dropbox, and Box:

- Joblens opens the provider sign-in in your browser
- after sign-in, the app returns to Joblens
- Joblens prepares its folder and syncs in the background

For Nextcloud:

- you enter:
  - server URL
  - username
  - app password

### One active provider at a time

Joblens is designed around one active cloud provider connection at a time for a signed-in account.

If one provider is already connected, the other disconnected providers are not available until you disconnect the active one.

### Sync status

The sync screen shows the current background state, including:

- queued jobs
- active uploads
- failed jobs

### Sync activity

Open `Sync Activity` from the sync status card to:

- review recent sync entries
- export the sync log
- clear the sync log

### Rescan cloud

`Rescan cloud` asks Joblens to reconcile synced projects against the connected cloud provider.

Use this when:

- you signed in on a new device
- files already exist in the cloud and you want Joblens to discover them
- you think cloud content changed outside the app

## Local-first behavior

Joblens is designed to feel immediate on the device.

That means:

- new photos appear right away
- moving photos between projects happens right away
- imports appear right away
- project edits appear right away
- cloud sync happens afterward in the background

If the phone is offline, you can still:

- open the app
- capture photos
- browse photos already on the device
- organize projects
- edit notes

Cloud work resumes when connectivity and account state are available again.

## Appearance

Open `Settings > Appearance` to choose the app theme.

Available options:

- `System`
- `Light`
- `Dark`

The selected theme is saved and restored the next time the app opens.

## Storage

Open `Settings > Storage` to manage import behavior.

### Storage features

- open the import screen
- choose import mode:
  - `Move`
  - `Copy`

This setting controls what happens to the original file in your phone library when importing into Joblens.

## Library status

The Settings screen shows a simple library summary:

- number of photos
- number of projects
- number of sync jobs

## Typical workflows

### Capture photos on a new job

1. Open `Camera`
2. Capture one or more photos
3. Open `Gallery` or `Projects`
4. Move the photos if needed, or capture directly into the correct project target

### Create and organize a project

1. Open `Projects`
2. Tap `Create project`
3. Enter the project name
4. Optionally set a start date
5. Open the project and add notes

### Import older photos from your device

1. Open `Settings > Storage`
2. Choose `Move` or `Copy`
3. Open `Import photos`
4. Select images from the phone library
5. Tap `Import`

### Turn on sync on a second device

1. Install Joblens on the new device
2. Open `Settings > Account`
3. Sign in to the same Joblens account
4. Open `Settings > Cloud sync`
5. Pull to refresh or tap `Rescan cloud`
6. Existing projects and synced photos should appear

## Troubleshooting

### I can use the app, but cloud sync is unavailable

Check:

- you are signed into Joblens
- a provider is connected
- the phone has internet access

### I signed in on a new device but do not see everything yet

Try:

1. Open `Settings > Cloud sync`
2. Pull to refresh
3. Tap `Rescan cloud`
4. Tap `Run sync now`

### I forgot my password

Use the `Forgot password?` link on the sign-in screen.

### I only want to use Joblens locally

That is supported. You can keep using the app for capture and organization without enabling cloud sync.

## Current feature summary

Today, Joblens supports:

- direct camera capture inside Joblens
- rapid multi-shot capture
- capture targets for Inbox, last used project, or a specific project
- gallery import
- local-first organization
- projects with metadata and notes
- account sign-in and recovery flows
- optional cloud sync through connected providers
- light and dark theme selection
