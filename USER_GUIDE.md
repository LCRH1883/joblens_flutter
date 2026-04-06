# Joblens User Guide

This guide explains how to use Joblens on iPhone and Android.

Joblens is a photo capture and organization app built for job-site workflows. You can use it locally on one device, or sign in and sync your library through your own connected cloud storage.

## What Joblens does

- Capture photos directly inside Joblens
- Import photos from your phone gallery
- Organize photos into projects
- Add notes to projects
- Sync your library through your connected cloud provider
- Keep using the app even when you are offline

## Main navigation

The bottom menu has four sections:

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

Cloud sync is optional for basic local use. If you are offline or not signed in, you can still capture photos and organize them on the device.

## Camera

Open `Camera` from the bottom navigation to capture photos directly in the app.

### Camera features

- Back button to return to the app
- Front/rear camera switching
- Flash mode toggle
- Zoom presets
- `Single` capture mode
- `Rapid` capture mode for taking multiple photos without leaving the camera

### How capture works

- `Single` mode uses the highest available capture quality
- `Rapid` mode is optimized for faster multi-shot capture
- New photos are added to Joblens right away
- Cloud sync happens in the background after the local save

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
- Import photos from the phone gallery

### Full-screen photo viewer

When you open a photo:

- Swipe left or right to move through photos
- Pinch to zoom
- Joblens uses the local file when available
- If the photo is cloud-only, Joblens loads it through the sync backend

## Importing from your phone gallery

You can import existing photos from your phone into Joblens.

There are two ways to reach import:

- `Gallery > Import photos`
- `Settings > Storage > Import photos`

### Import behavior

In `Settings > Storage`, you can choose how imports work:

- `Move`
  - imports the photo into Joblens
  - removes the original from the phone after import
- `Copy`
  - imports the photo into Joblens
  - keeps the original in the phone gallery

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

When creating a project, the user can set:

- project name
- optional start date

### Editing a project

Project editing lets the user update:

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

Notes are edited from the project detail screen using the notes button in the top bar.

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

If email confirmation is enabled, Joblens will show a confirmation screen after sign-up.

From there, the user can:

- resend the confirmation email
- go back to sign in

If the user opens the email link on their phone, the app should return directly to Joblens.

### Forgot password

From the sign-in screen:

1. Tap `Forgot password?`
2. Enter the account email
3. Open the reset email
4. Return to Joblens
5. Set a new password

## Cloud sync

Open `Settings > Cloud sync` to manage provider connections and background sync.

### What cloud sync does

Cloud sync connects your Joblens account to your own cloud storage provider. Joblens then uses the backend to coordinate uploads, downloads, and cross-device synchronization.

### Providers

The app is built to support:

- Google Drive
- OneDrive
- Dropbox
- Box
- Nextcloud

### Sync page features

- See whether you are signed in
- See current provider connection status
- Connect a provider
- Disconnect a provider
- Run sync now
- Retry failed sync jobs
- Open sync activity details

### How provider connection works

For Google Drive, OneDrive, Dropbox, and Box:

- Joblens opens the provider login in the browser
- after sign-in, the app returns to Joblens

For Nextcloud:

- the user enters:
  - server URL
  - username
  - app password

### Sync status

The sync screen shows the current background state, including:

- queued jobs
- active uploads
- failed jobs

## Local-first behavior

Joblens is designed to feel immediate on the device.

That means:

- new photos appear right away
- moving photos between projects happens right away
- imports appear right away
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

This setting controls what happens to the original file in your phone gallery when importing into Joblens.

## Library status

The Settings screen shows a simple library summary:

- number of photos
- number of projects
- number of sync jobs

## Typical workflows

### Capture photos on a new job

1. Open `Camera`
2. Capture one or more photos
3. Open `Gallery`
4. Select the new photos
5. Move them into the correct project

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
4. Select images from the phone gallery
5. Tap `Import`

### Turn on sync on a second device

1. Install Joblens on the new device
2. Open `Settings > Account`
3. Sign in to the same Joblens account
4. Open `Settings > Cloud sync`
5. Refresh or run sync
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
3. Tap `Run sync now`

### I forgot my password

Use the `Forgot password?` link on the sign-in screen.

### I only want to use Joblens locally

That is supported. You can keep using the app for capture and organization without enabling cloud sync.

## Current feature summary

Today, Joblens supports:

- in-app photo capture
- rapid multi-shot capture
- gallery import
- local-first organization
- projects with metadata and notes
- account sign-in and recovery flows
- optional cloud sync through connected providers
- light and dark theme selection
