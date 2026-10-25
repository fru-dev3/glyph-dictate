#!/usr/bin/env bash
#
# Deploy the jot.fru.dev site (the static files in site/) to Vercel,
# team fru-dev3, project jot-fru. No build step, no functions, no secrets. Since 2026-10-25 the
# site is only redirects to https://glyph.fru.dev/dictate (see vercel.json).
#
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .vercel/project.json ] || vercel link --yes --project jot-fru

echo "building"
vercel build --prod --yes

# Deploys the prebuilt output from a copy outside the repo. Run inside it, the
# CLI attaches the git commit, and Vercel has blocked such deployments ("the
# commit author doesn't have permission") and left the CLI stuck at Building.
vdeploy() {
  local stage; stage=$(mktemp -d)
  mkdir "$stage/.vercel"
  cp -R .vercel/project.json .vercel/output "$stage/.vercel/"
  (cd "$stage" && vercel deploy "$@"); local rc=$?
  rm -rf "$stage"
  return $rc
}

echo "deploying"
vdeploy --prebuilt --prod

# jot.fru.dev is retired (Jot is now Glyph Dictate): every page 301s to glyph.fru.dev/dictate,
# /download still serves the DMG and /privacy.html (the app's policy link) is still served.
r=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' https://jot.fru.dev/)
[ "$r" = "301 https://glyph.fru.dev/dictate" ] || { echo "jot.fru.dev/ answered $r"; exit 1; }
[ "$(curl -s -o /dev/null -w '%{http_code}' -L https://jot.fru.dev/download)" = 200 ] || { echo "/download does not reach the DMG"; exit 1; }
[ "$(curl -s -o /dev/null -w '%{http_code}' https://jot.fru.dev/privacy.html)" = 200 ] || { echo "/privacy.html is not served"; exit 1; }
echo "live: jot.fru.dev redirects to https://glyph.fru.dev/dictate"
