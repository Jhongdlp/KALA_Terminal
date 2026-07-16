#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Dynamically extract GitHub token from origin remote URL to avoid hardcoding credentials
TOKEN=$(git remote get-url origin | sed -n 's/.*:\(ghp_[^@]*\)@.*/\1/p')
REPO="Jhongdlp/KALA_Terminal"

if [ -z "$TOKEN" ]; then
  echo "Error: Could not extract GitHub Personal Access Token from git remote URL." >&2
  exit 1
fi

# Read version
line=$(grep '^version:' pubspec.yaml | head -1)
current=${line#version: }
name=${current%%+*}
build=${current#*+}
IFS='.' read -r major minor patch <<<"$name"

# Bump patch and build
patch=$((patch + 1))
new_name="${major}.${minor}.${patch}"
new_build=$((build + 1))
tag="v${new_name}"

echo "==> Bumping version: ${name}+${build} -> ${new_name}+${new_build} (tag ${tag})"

# Write new version to pubspec.yaml
sed -i.bak "s/^version: .*/version: ${new_name}+${new_build}/" pubspec.yaml && rm -f pubspec.yaml.bak

# Compile APK
echo "==> Building APK..."
export JAVA_HOME="/home/emi/StudioProjects/KALA_Terminal/sdk/jdk"
sdk/flutter/bin/flutter build apk --release

apk="build/app/outputs/flutter-apk/app-release.apk"
if [ ! -f "$apk" ]; then
  echo "Error: APK not found at $apk" >&2
  exit 1
fi

# Git operations
echo "==> Committing and pushing..."
git add pubspec.yaml
git commit -m "release: ${new_name}+${new_build}"
git tag "$tag"
git push origin main
git push origin "$tag"

# Create release on GitHub via curl
echo "==> Creating GitHub Release ${tag}..."
release_response=$(curl -s -X POST -H "Authorization: token ${TOKEN}" \
  -H "Accept: application/vnd.github.v3+json" \
  -d "{\"tag_name\":\"${tag}\",\"target_commitish\":\"main\",\"name\":\"${tag}\",\"body\":\"Versión ${new_name}\",\"draft\":false,\"prerelease\":false}" \
  "https://api.github.com/repos/${REPO}/releases")

# Parse release ID
release_id=$(echo "$release_response" | grep -m1 '"id":' | sed 's/[^0-9]//g')

if [ -z "$release_id" ]; then
  echo "Error: Failed to create release. Response was:"
  echo "$release_response"
  exit 1
fi

echo "==> Created release with ID: ${release_id}"

# Upload asset via curl
echo "==> Uploading APK..."
upload_response=$(curl -s -X POST -H "Authorization: token ${TOKEN}" \
  -H "Accept: application/vnd.github.v3+json" \
  -H "Content-Type: application/vnd.android.package-archive" \
  --data-binary @"${apk}" \
  "https://uploads.github.com/repos/${REPO}/releases/${release_id}/assets?name=app-release.apk")

# Verify upload
if echo "$upload_response" | grep -q '"browser_download_url"'; then
  echo "==> Upload successful!"
  download_url=$(echo "$upload_response" | grep '"browser_download_url"' | cut -d'"' -f4)
  echo "Download URL: ${download_url}"
else
  echo "Error: Failed to upload asset. Response was:"
  echo "$upload_response"
  exit 1
fi

echo "✅ Successfully released ${tag} to GitHub!"
