#!/usr/bin/env node
// npx agent-traffic-light — a thin wrapper around install.sh.
//
// Deliberately thin. The shell script is the implementation for people who
// cloned the repo, and duplicating it in JavaScript would mean two installers
// drifting apart. Node's only job here is to be the thing `npx` can run.
//
// It is also worth being explicit that node appears exactly once, at install
// time. The hooks are shell, measured at 2.8 ms per fire against node's
// 16.8 ms, and a global npm install would break every time nvm switched
// versions. Nothing in the running system depends on this file.

'use strict';

const { spawnSync } = require('node:child_process');
const { existsSync } = require('node:fs');
const path = require('node:path');
const os = require('node:os');

const root = path.resolve(__dirname, '..');
const installer = path.join(root, 'install.sh');
const binary = path.join(os.homedir(), '.local', 'bin', 'traffic-light');

const argv = process.argv.slice(2);

// The first bare word is the command; everything starting with a dash is a
// flag for install.sh. Splitting them rather than taking argv[0] is what makes
// `--yes install`, `install --yes` and a bare `--local` all mean the same
// thing — the old parser read argv[0] only, so a leading flag was taken for a
// command and sent to the binary, which does not know any of them.
const command = argv.find((a) => !a.startsWith('-')) ?? 'install';
const flags = argv.filter((a) => a.startsWith('-'));
const rest = argv.filter((a) => a !== command);

const HELP = `
  npx agent-traffic-light install             build, start, install the hooks
  npx agent-traffic-light install --local     hooks in this directory only
  npx agent-traffic-light install --dry-run   say what that would do, do nothing
  npx agent-traffic-light uninstall           stop and remove
  npx agent-traffic-light uninstall --purge   also remove settings, state, logs

  Add --yes to skip the confirmation. Nothing is written before it has told
  you what it will write.

  Once installed, use the binary directly — it is faster and does not
  need node:

      traffic-light status            every live session and its Signal
      traffic-light doctor            check the install, say what to fix
      traffic-light preview           every Signal, wording and chime
      traffic-light broken "<why>"    mark this session Broken
      traffic-light cleanup           drop finished sessions now

`;

function fail(message) {
  process.stderr.write(`agent-traffic-light: ${message}\n`);
  process.exit(1);
}

function run(cmd, args) {
  const result = spawnSync(cmd, args, { stdio: 'inherit' });
  if (result.error) fail(result.error.message);
  process.exit(result.status ?? 1);
}

if (process.platform !== 'darwin') {
  fail('macOS only — it renders a menu bar item and a floating panel.');
}

if (argv.includes('-h') || argv.includes('--help') || argv.includes('help')) {
  process.stdout.write(HELP);
  process.exit(0);
}

switch (command) {
  case 'install':
  case 'uninstall':
    if (!existsSync(installer)) fail(`install.sh missing from the package at ${root}`);
    // The installer names the undo command in its own plan, and it has to name
    // the one this reader actually typed rather than the shell form.
    process.env.TRAFFIC_LIGHT_VIA_NPX = '1';
    run('sh', [installer, command, ...flags]);
    break;

  default:
    // Anything else is a command the installed binary owns. Passing it through
    // means `npx agent-traffic-light doctor` works before someone has put
    // ~/.local/bin on their PATH — which is exactly when they need doctor.
    if (!existsSync(binary)) {
      fail(`not installed yet — run:  npx agent-traffic-light install`);
    }
    run(binary, [command, ...rest]);
}
