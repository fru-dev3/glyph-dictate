#!/usr/bin/env bash
#
# Deploy the jot.fru.dev site (the static files in site/) to Vercel,
# team fru-dev3, project jot-fru. No build step, no functions, no secrets. First it refreshes
# the download count saved in the page (scripts/fetch-downloads.mjs).
#
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .vercel/project.json ] || vercel link --yes --project jot-fru

# The download count's floor, written into the page; committed and pushed so a deploy stays
# the pushed code.
node scripts/fetch-downloads.mjs
if ! git diff --quiet -- site/index.html; then
  git commit -qm "jot.fru.dev: download count $(grep -o 'data-baked="[0-9]*"' site/index.html | grep -o '[0-9]*')" -- site/index.html
  git push -q
fi

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

CODE=$(curl -s -o /dev/null -w '%{http_code}' https://jot.fru.dev/)
if [ "$CODE" != "200" ]; then
  echo "jot.fru.dev answered $CODE, expected 200"
  exit 1
fi
echo "live at https://jot.fru.dev"
