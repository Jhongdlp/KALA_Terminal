#!/usr/bin/env bash
#
# Automated release: bump version in pubspec.yaml, build the release APK, and
# publish it to GitHub Releases so installed apps auto-update
# (see lib/services/update_service.dart).
#
# Usage:
#   ./scripts/release.sh            # bump patch  (1.0.0 -> 1.0.1)
#   ./scripts/release.sh minor      # bump minor  (1.0.3 -> 1.1.0)
#   ./scripts/release.sh major      # bump major  (1.2.0 -> 2.0.0)
#   ./scripts/release.sh 1.4.2      # set an exact version
#
# Requires: flutter on PATH (or sdk/flutter/bin), gh authenticated
# (`gh auth login`), python3, and an entry for the new version in
# lib/models/changelog.dart.

set -euo pipefail
cd "$(dirname "$0")/.."

# --- locate flutter -------------------------------------------------------
if command -v flutter >/dev/null 2>&1; then
  FLUTTER=flutter
elif [ -x sdk/flutter/bin/flutter ]; then
  FLUTTER=sdk/flutter/bin/flutter
else
  echo "error: flutter not found on PATH or in sdk/flutter/bin" >&2
  exit 1
fi

command -v gh >/dev/null 2>&1 || { echo "error: gh (GitHub CLI) not installed" >&2; exit 1; }

# --- read current version  (e.g. "1.0.0+1") -------------------------------
line=$(grep '^version:' pubspec.yaml | head -1)
current=${line#version: }
name=${current%%+*}          # 1.0.0
build=${current#*+}          # 1
IFS='.' read -r major minor patch <<<"$name"

# --- compute the next version --------------------------------------------
arg=${1:-patch}
case "$arg" in
  patch) patch=$((patch + 1)) ;;
  minor) minor=$((minor + 1)); patch=0 ;;
  major) major=$((major + 1)); minor=0; patch=0 ;;
  *.*.*) IFS='.' read -r major minor patch <<<"$arg" ;;
  *) echo "error: unknown argument '$arg' (use patch|minor|major|X.Y.Z)" >&2; exit 1 ;;
esac
new_name="${major}.${minor}.${patch}"
new_build=$((build + 1))
tag="v${new_name}"

echo "==> ${name}+${build}  ->  ${new_name}+${new_build}  (tag ${tag})"

# --- guard: tag must not already exist ------------------------------------
if gh release view "$tag" >/dev/null 2>&1; then
  echo "error: release $tag already exists on GitHub" >&2
  exit 1
fi

# --- guard: the changelog must describe this version ----------------------
# lib/models/changelog.dart is what the app's NOVEDADES screen shows and what
# the release body below is generated from. Checked *before* the version bump
# so a missing entry costs nothing to fix.
if ! python3 scripts/changelog_notes.py --check "$new_name"; then
  exit 1
fi

# --- write the new version back into pubspec.yaml -------------------------
# Portable in-place edit (works on both GNU and BSD sed).
sed -i.bak "s/^version: .*/version: ${new_name}+${new_build}/" pubspec.yaml && rm -f pubspec.yaml.bak

# --- build ----------------------------------------------------------------
echo "==> building release APK…"
"$FLUTTER" build apk --release
apk="build/app/outputs/flutter-apk/app-release.apk"
[ -f "$apk" ] || { echo "error: APK not found at $apk" >&2; exit 1; }

# --- commit + tag + push the version bump ---------------------------------
git add pubspec.yaml
git commit -m "release: ${new_name}+${new_build}" >/dev/null
git tag "$tag"
echo "==> pushing commit + tag…"
git push origin HEAD
git push origin "$tag"

# --- publish the GitHub release -------------------------------------------
echo "==> creating GitHub release ${tag}…"
# Generated in English from the in-app changelog, so the body a user sees
# before installing always matches what NOVEDADES will show them afterwards —
# and is never left in whatever language the release was written in.
# RELEASE_NOTES still overrides it for a one-off.
notes=${RELEASE_NOTES:-"$(python3 scripts/changelog_notes.py "$new_name")"}
gh release create "$tag" "$apk" --title "$tag" --notes "$notes"

echo
echo "✅ Released ${tag} and published to GitHub."
