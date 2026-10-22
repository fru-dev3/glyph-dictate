// The download count's floor: sums every Jot .dmg downloaded from GitHub Releases and writes it
// into site/index.html (data-baked on #dlc). The page asks GitHub live and never shows less than
// this. A failure or a lower answer keeps the old number. Run by scripts/ship.sh.
import { readFileSync, writeFileSync } from "node:fs";
import { execSync } from "node:child_process";

const page = new URL("../site/index.html", import.meta.url);
const html = readFileSync(page, "utf8");
const was = Number(html.match(/data-baked="(\d+)"/)?.[1] ?? 0);
const headers = { Accept: "application/vnd.github+json" };
try { headers.Authorization = `Bearer ${execSync("gh auth token", { stdio: ["ignore", "pipe", "ignore"] }).toString().trim()}`; } catch {}

try {
  const r = await fetch("https://api.github.com/repos/fru-dev3/jot/releases?per_page=100", { headers });
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  let total = 0;
  for (const rel of await r.json())
    for (const a of rel.assets ?? []) if (/\.dmg$/.test(a.name) && typeof a.download_count === "number") total += a.download_count;
  if (total <= was) throw new Error(`got ${total}, keeping ${was}`);
  writeFileSync(page, html.replace(/data-baked="\d+"/, `data-baked="${total}"`));
  console.log(`downloads: ${was} -> ${total}`);
} catch (e) {
  console.log(`downloads: ${was} (${e.message})`);
}
