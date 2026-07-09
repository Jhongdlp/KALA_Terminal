#!/usr/bin/env bash
# Regenerates the agent notification badges (the full-color largeIcon shown on
# "agent alert" notifications — see AlertNotifier.kt). One disc per known agent
# plus a generic fallback; colors approximate each brand without shipping the
# trademarked logo. Requires ImageMagick with the DejaVu fonts.
set -euo pipefail
cd "$(dirname "$0")/.."

R=android/app/src/main/res/drawable-nodpi
mkdir -p "$R"

badge() { # name color pointsize y-offset glyph
  magick -size 192x192 xc:none \
    -fill "$2" -draw 'circle 95.5,95.5 95.5,6' \
    -fill white -font DejaVu-Sans-Bold -pointsize "$3" \
    -gravity center -annotate +0+"$4" "$5" "$R/$1.png"
}

badge ic_agent_claude      '#D97757' 150 28 '✳'
badge ic_agent_antigravity '#4285F4' 110 8  'A'
badge ic_agent_aider       '#1F9D55' 110 8  '>'
badge ic_agent_codex       '#10A37F' 110 8  'C'
badge ic_agent_gemini      '#6C7BF4' 150 28 '✦'
badge ic_agent_generic     '#5F6B7A' 84  4  '>_'

echo "Badges regenerados en $R/"
