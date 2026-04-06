#!/usr/bin/env bash

set -euo pipefail

PUB_CACHE_DIR="${PUB_CACHE:-$HOME/.pub-cache}/hosted/pub.dev"

python3 - "$PUB_CACHE_DIR" <<'PY'
from pathlib import Path
import sys

pub_cache = Path(sys.argv[1])

patches = {
    pub_cache / "app_links-7.0.0/android/build.gradle": [
        ("group 'com.llfbandit.app_links'", "group = 'com.llfbandit.app_links'"),
        ("version '1.0'", "version = '1.0'"),
    ],
    pub_cache / "photo_manager-3.9.0/android/build.gradle": [
        ("group 'com.fluttercandies.photo_manager'", "group = 'com.fluttercandies.photo_manager'"),
        ("version library_version", "version = library_version"),
        ("namespace 'com.flutterandies.photo_manager'", "namespace = 'com.flutterandies.photo_manager'"),
        ("compileSdkVersion 36", "compileSdk = 36"),
        ("minSdkVersion 16", "minSdk = 16"),
        ("sourceCompatibility JavaVersion.VERSION_17", "sourceCompatibility = JavaVersion.VERSION_17"),
        ("targetCompatibility JavaVersion.VERSION_17", "targetCompatibility = JavaVersion.VERSION_17"),
    ],
    pub_cache / "share_plus-10.1.4/android/build.gradle": [
        ("group 'dev.fluttercommunity.plus.share'", "group = 'dev.fluttercommunity.plus.share'"),
        ("version '1.0-SNAPSHOT'", "version = '1.0-SNAPSHOT'"),
        ("compileSdk 34", "compileSdk = 34"),
        ("namespace 'dev.fluttercommunity.plus.share'", "namespace = 'dev.fluttercommunity.plus.share'"),
        ("minSdk 19", "minSdk = 19"),
    ],
    pub_cache / "sqflite_android-2.4.2+2/android/build.gradle": [
        ("group 'com.tekartik.sqflite'", "group = 'com.tekartik.sqflite'"),
        ("version '1.0-SNAPSHOT'", "version = '1.0-SNAPSHOT'"),
        ("namespace 'com.tekartik.sqflite'", "namespace = 'com.tekartik.sqflite'"),
    ],
}

for path, replacements in patches.items():
    if not path.exists():
        print(f"skip: {path}")
        continue
    original = path.read_text()
    updated = original
    for old, new in replacements:
        updated = updated.replace(old, new)
    if updated != original:
        path.write_text(updated)
        print(f"patched: {path}")
    else:
        print(f"unchanged: {path}")
PY
