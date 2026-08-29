#!/usr/bin/env node
// What actually ends up in the tarball, checked before it can be published.
//
// `files` in package.json is an allowlist, which is the right shape — a file
// nobody listed does not ship. But naming a *directory* takes everything
// inside it as it exists on disk, and `.gitignore` does not filter that: a
// gitignored file inside an allowlisted directory ships anyway. `git status`
// stays clean, nothing complains, and the pack manifest is the only place it
// shows.
//
// `docs` is no longer in the allowlist at all — nothing under it is needed to
// install or run anything. The patterns below stay anyway, because the failure
// was never one directory in particular: it was naming a directory and
// inheriting whatever later lands inside it.
//
// Hence this. It runs from `prepublishOnly`, so it cannot be forgotten, and it
// fails the publish rather than printing a warning nobody reads.
//
// Note for anyone auditing this package: `prepublishOnly` runs on the
// *publisher's* machine at publish time. It is not an install hook — nothing
// here ever executes on a user's machine. This package deliberately has no
// install-time scripts at all.

import { execFileSync } from 'node:child_process';

// Things that must never ship, whatever the allowlist says.
const FORBIDDEN = [
  // `docs` is not in the allowlist, so nothing under it should ever appear.
  // One pattern for the whole tree rather than a list of its subdirectories:
  // a guard that enumerates what it protects goes stale as soon as something
  // new lands beside them.
  [/(^|\/)docs\//, 'anything under docs'],
  [/(^|\/)\.scratch\//, 'local working files'],
  [/(^|\/)node_modules\//, 'dependencies'],
  [/(^|\/)\.git\//, 'git internals'],
  [/(^|\/)\.github\//, 'CI config'],
  [/(^|\/)\.claude\//, 'local tooling'],
  [/\.env(\.|$)/, 'environment files'],
  [/\.DS_Store$/, 'Finder junk'],
  [/\.tgz$/, 'a previous tarball'],
  [/\.log$/, 'logs'],
];

// Things the installer reaches for at runtime. If one of these is missing the
// package installs and then fails on the user's machine, which is worse than
// not publishing.
const REQUIRED = [
  'package.json',
  'bin/cli.js',
  'install.sh',
  'LICENSE',
  'README.md',
  'hooks/hooks.json',
  'hooks/traffic-light-hook.sh',
  'daemon/Package.swift',
  '.claude-plugin/plugin.json',
  '.claude-plugin/marketplace.json',
];

// Tripwires, not targets: set loose enough not to nag on ordinary growth, and
// tight enough that a whole directory arriving by accident trips them.
const MAX_FILES = 60;
const MAX_BYTES = 400_000;

// --ignore-scripts so this cannot re-enter itself through a lifecycle hook.
const raw = execFileSync(
  'npm', ['pack', '--dry-run', '--json', '--ignore-scripts'],
  { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] },
);
const [manifest] = JSON.parse(raw);
const paths = manifest.files.map((f) => f.path);
const problems = [];

for (const [pattern, what] of FORBIDDEN) {
  const hits = paths.filter((p) => pattern.test(p));
  if (hits.length) {
    problems.push(
      `${hits.length} file(s) of ${what} would ship, e.g. ${hits[0]}`,
    );
  }
}

for (const needed of REQUIRED) {
  if (!paths.includes(needed)) problems.push(`missing: ${needed}`);
}

if (manifest.entryCount > MAX_FILES) {
  problems.push(
    `${manifest.entryCount} files, over the ${MAX_FILES} tripwire — ` +
    `something arrived that nobody meant to send`,
  );
}
if (manifest.size > MAX_BYTES) {
  problems.push(
    `${Math.round(manifest.size / 1024)} kB packed, over the ` +
    `${Math.round(MAX_BYTES / 1024)} kB tripwire`,
  );
}

const summary =
  `${manifest.name} ${manifest.version} — ${manifest.entryCount} files, ` +
  `${Math.round(manifest.size / 1024)} kB packed`;

if (problems.length) {
  console.error(`\n  Refusing to publish. ${summary}\n`);
  for (const p of problems) console.error(`    ✗ ${p}`);
  console.error(
    '\n  Fix the "files" list in package.json, then run this again:\n' +
    '      node scripts/check-package.mjs\n',
  );
  process.exit(1);
}

console.log(`  ✓ ${summary}`);
console.log(`  ✓ nothing forbidden, and all ${REQUIRED.length} required paths present`);
