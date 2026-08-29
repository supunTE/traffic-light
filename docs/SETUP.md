# Setting up Traffic Light

Follow this top to bottom. It takes about five minutes, plus a few more if you want push to your phone.

If anything goes wrong, `traffic-light doctor` will tell you which part is broken and the command that fixes it. Reach for it before reading the troubleshooting section.

## What you need

| | Why | Required? |
|---|---|---|
| macOS 14 or later | the daemon uses SF Symbols and modern AppKit | yes |
| Xcode Command Line Tools | the daemon is built from source on your machine — `xcode-select --install`, not full Xcode | yes |
| Node 18+ | only to run `npx` once; nothing afterwards uses it | for npx |
| Claude Code | it's what's being watched | yes |
| Docker | only for running your own push server | optional |

Check the two that matter:

```bash
swift --version && sw_vers -productVersion
```

There is **nothing to download** — no `.app` on a website, no installer package. You get a
real `Traffic Light.app` all the same; it is compiled here and assembled locally. See
*[Why the app is built, not downloaded](../README.md#why-the-app-is-built-not-downloaded)*
for why that distinction is the whole trick.

## 1. Install

```bash
npx agent-traffic-light install
```

It prints everything it is about to write — every path, every step, and the two
lines it adds to your Claude Code settings — then waits for a yes. Nothing happens
before that. To read the plan without committing to anything:

```bash
npx agent-traffic-light install --dry-run
```

`--yes` skips the question, which is what you want in CI or when reinstalling.
There is no terminal to ask on in either case, so without `--yes` the installer
stops and says so rather than assuming you agreed.

Saying yes does all of it: compiles the daemon, builds **Traffic Light.app** into
`~/Applications`, puts the same binary in `~/.local/bin/traffic-light` for the command
line, registers it in macOS Login Items so it starts at login (falling back to a LaunchAgent
if macOS refuses), and installs the hooks. Takes about a minute, most of it the build.

The app is built on your machine rather than downloaded, so it carries no quarantine
attribute — Gatekeeper never inspects it, and nothing needs signing or notarizing. Drag it
to `/Applications` if you prefer it there; nothing depends on where it sits.

**Quit means quit.** The menu item exits and the light stays off until you next log in, or
until you open the app again. A crash is still recovered within the second — launchd is
told to relaunch only on an unsuccessful exit.

The hooks go in at **user scope** — every project — because one light for every session you have running is the whole point. To try it on a single project first, or if you are working on Traffic Light itself:

```bash
npx agent-traffic-light install --local
```

That declares the plugin in the current directory's `.claude/settings.local.json` and leaves `~/.claude/settings.json` alone entirely.

From a clone instead — identical, since the npx package is a wrapper around this script:

```bash
git clone https://github.com/supunTE/traffic-light.git
cd traffic-light && sh install.sh
```

**Node is used once and never again.** The hooks are shell — measured at 2.8 ms per fire against node's 16.8 ms — and a global npm install would break every time `nvm` switched versions. Nothing in the running system depends on node.

If `~/.local/bin` isn't on your `PATH`, the installer says so. Add it:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
```

You should now see a thin white ring in your menu bar. A white ring means *nothing is reporting yet* — correct, because no session has restarted. The floating bar stays hidden until a session actually reports.

### About the hooks

They ship as a **Claude Code plugin**, which the installer registers for you. That's deliberate: a plugin is one toggle to enable or disable, and **no hooks are ever merged into your `settings.json`**. Two lines land there — `extraKnownMarketplaces` and `enabledPlugins` — the same entries every plugin gets.

The plugin is installed from a copy at `~/Library/Application Support/traffic-light/plugin`, not from wherever you ran the installer. Under `npx` that directory is an npm cache which can be cleared at any time, and a marketplace pointing into a deleted folder is worse than none. It also means the hooks need neither a network nor a cloned repo.

If the installer couldn't reach the `claude` CLI it prints the two manual commands; run them in Claude Code.

> **Hooks load when a session starts.** If the light stays white after
> installing, open a new session — or restart Claude.

## 2. Check it

```bash
traffic-light doctor
```

```
  ✓ state directory   ~/Library/Application Support/traffic-light
  ✓ daemon            state 2s old
  ✓ inbox             0 pending
  ✓ claude sessions   2 live
  ✓ hooks             all 2 sessions reporting
  ! push              disabled
  ✓ bell              3 sounds resolve
```

`traffic-light status` prints the same picture the menu bar is showing.

## 3. Push to your phone (optional)

Push uses [ntfy](https://ntfy.sh) — notify-only, no account, no per-session pairing, and it reaches you from every worktree at once. You have two choices.

### Option A — your own server

Nothing leaves your network.

```bash
sh scripts/setup-ntfy.sh
```

It starts an ntfy server in Docker and prints the address. Put it in `push.server` in `~/Library/Application Support/traffic-light/config.json` — the Settings window shows the server but does not edit it, and the script deliberately does not write the file for you. The topic comes from **Settings → Notifications**.

> **ntfy's server does not run natively on macOS.** Both `brew install ntfy` and the official `ntfy_*_darwin_all.tar.gz` are client-only builds — `publish` and `subscribe` only, and `serve` fails with `No help topic for 'serve'`. Docker is the only supported route on a Mac.

Without Tailscale the script falls back to your LAN address, which only reaches your phone on the same WiFi. Install Tailscale on the Mac and the phone, then re-run the script — it picks up the tailnet hostname automatically and push then works from anywhere.

**On an iPhone**, background delivery is only possible through Apple's APNs, so a self-hosted server can't wake your phone by itself. The generated config sets `upstream-base-url`, which sends a *contentless* poll request via ntfy.sh; your phone then fetches the real message from your server. No message content leaves your network. **On Android** the app connects straight to your server and ntfy.sh is never involved — delete that line if you have no iPhone.

### Option B — public ntfy.sh

Zero setup, works from anywhere immediately. In `config.json` set `push.enabled` to `true` and `push.server` to `https://ntfy.sh`, then subscribe to your topic in the app.

Understand the trade first: **on ntfy the topic name is the entire access control**, and session names are derived from your directory names. A public topic tells anyone who has it which projects you work on. Message text is never sent unless you turn on `includeText`. Fine for hobby projects; wrong for a client under NDA.

### Then, on your phone

Install the ntfy app, set **Settings → Default server** to your server's address, and subscribe to the topic. `traffic-light doctor` confirms the server is reachable from the Mac, and its
`push topic` line reads the topic back to say whether messages are actually
landing on it. It cannot tell whether your phone is subscribed — ntfy publishes
no subscriber count — but it does separate "the Mac never sent" from "the phone
never heard", which is otherwise guesswork.

### What a notification looks like

The title is the session, so several of them are told apart at a glance, and
the icon is the state:

```
🚨 api-server          Crashed
❓ traffic-light       Waiting for your answer
✅ docs-site           Your turn
```

Sessions that stop at the same moment arrive as one notification rather than
one buzz and a silence — the most urgent sets the icon and how insistently the
phone announces it:

```
🚨 3 sessions
api-server — Crashed
traffic-light — Waiting for your answer
docs-site — Your turn
```

`minIntervalSeconds` limits how often you are interrupted, not how much you are
told: anything that happens inside the window waits and travels with the next
one. A session that changes again while waiting — you answered it at the desk —
is dropped rather than delivered out of date.

## Configuration

`~/Library/Application Support/traffic-light/config.json`, written with defaults the first time the daemon runs.

```jsonc
{
  "bell": {
    "enabled": true,
    "minIntervalSeconds": 2,        // several sessions finishing at once ring once
    "volume": 1,                    // 0 to 1
    "sounds": {                     // any name from /System/Library/Sounds
      "Broken": "Basso",
      "Asking": "Ping",
      "Done":   "Glass"
    }                               // Working and Idle are silent on purpose
  },
  "push": {
    "enabled": false,
    "server": "https://ntfy.sh",    // the default; a LAN server
                                    // looks like http://192.168.1.3:2586
    "topic": "traffic-light-…",     // this string is the password — keep it secret
    "signals": ["Broken","Asking","Done"], // every way a Session stops;
                                    // Working and Idle never push
    "includeText": false,           // see the warning below
    "minIntervalSeconds": 10,
    "priorities": {}                // per-Signal ntfy priority, see below
  },
  "attention": {                    // Quiet hours, the menu snooze, per-project rules
    "windows": [],                  // easier to set in Settings than by hand
    "projects": []
  },
  "bar": {
    "visible": true,
    "size": 22,                     // bulb size in points, 14–36
    "horizontal": false             // a row instead of a column, names underneath
  },
  "log": {                          // developers only, see above
    "enabled": false,               // off unless you are working on Traffic Light
    "includeText": false,           // sizes only, not the words
    "maxBytes": 16777216            // rotates once at this size, so 32MB max
  }
}
```

### What else is on disk

Everything lives in the same directory, all of it 0600.

| File | Written by | What it is |
|---|---|---|
| `config.json` | you, and Settings | Everything above. Yours to edit. |
| `state.json` | the daemon | What is true this second, rewritten as sessions change and at least every two seconds so a health check can tell a quiet daemon from a dead one. No history. |
| `projects.json` | the daemon | Every project it has seen, and when — so the Projects tab can offer one that is not running right now. Capped at 40, and anything carrying a rule is never dropped. |
| `events.jsonl` | the daemon, when you ask | The event log below. Absent unless you switch it on. |

Delete any of them while the daemon runs; it recreates what it needs.

**`includeText` sends your prompts and Claude's replies.** `UserPromptSubmit` carries the full prompt text and `Stop` carries the entire assistant message. Turning this on publishes them to your topic. Leave it off unless you run your own server and understand what you're doing.

**Edits take effect within a second — no restart.** The daemon stats the file each tick and reloads only when it changes, so turning the bell off or swapping a sound applies while you watch.

For the sounds specifically, don't edit JSON:

```bash
traffic-light preview
```

That opens a panel with every Signal, every wording it can carry, and a picker per Signal plus a grid to audition all fourteen system sounds. Choices save immediately and the running daemon picks them up — so you can set a chime and hear it fire on a real transition straight after.

## Using it

```bash
traffic-light status              # every live session and its Signal
traffic-light doctor              # check the install
traffic-light preview             # every Signal, wording and chime
traffic-light broken "<reason>"   # Distress Call — mark this session Broken
traffic-light cleanup             # drop finished sessions now, without waiting
```

A session whose process has gone is dropped an hour after its last event, so a
restart in progress is never mistaken for a death. `cleanup` is for when you
have already looked at a row and know it is finished — it collects everything
whose process is gone, and touches nothing that is still running. Add `--logs`
to delete the event log with it.

A session that is still running but has said nothing for eight hours fades to a
half-weight ring and stops driving the menu bar. It is not hidden: the row says
how long it has been quiet, because a forgotten session may still be holding
real memory.

Before `~/.local/bin` is on your `PATH`, `npx agent-traffic-light <command>` passes through to the same binary — which is handy for `doctor` exactly when you need it.

`broken` is meant to be run *by Claude*, from inside a session, when it hits something it can't resolve. It works out which session it's in by walking its own process ancestry, so it needs no arguments beyond the reason. It's also the only route to a red light that carries an explanation — every other state is inferred from hooks, and a session looping on the same error fires exactly the same events as one making progress.

**Claude does not know the command exists.** Nothing in the plugin tells it, so
without an instruction somewhere it will never run this. The installer asks
separately whether to add a short paragraph to `~/.claude/CLAUDE.md`, in a
marked block that `uninstall` removes again; answering no leaves the file
untouched. Re-running the installer is how you add it later, and it updates the
block in place rather than adding a second copy.

Writing your own instead is fine — put it wherever Claude reads standing
instructions. Give it a threshold, whatever the wording: without one the honest
failure mode is a red light on every transient error, and a light that cries
wolf is worse than no light at all.

Click any session in the menu to bring Claude to the front — the app, not that
specific session, which no URL scheme can reach. Drag the floating bar anywhere.

## The event log (developers only)

`~/Library/Application Support/traffic-light/events.jsonl` can record every hook payload
the daemon ingests. **It is off by default and deliberately absent from Settings** — it
answers questions about Traffic Light's own behaviour, not about your sessions, and it is
not worth a file on your disk unless you are chasing one of them.

Switch it on by editing `config.json`:

```jsonc
"log": { "enabled": true, "includeText": false, "maxBytes": 16777216 }
```

Leave `includeText` off unless you specifically need the words. Measured over three days:
85 % of the file was message text, and none of the questions the log exists for reads it.
The file is 0600, rotates once at `maxBytes`, and every write failure is swallowed — the
log is the least important thing the daemon does and must never be able to stop the light.

## When it doesn't work

Almost every failure here is silent — a light that says nothing looks exactly like a light that says everything is fine. Run `doctor` first.

| Symptom | Cause | Fix |
|---|---|---|
| Light stays white, `doctor` says *no live session is sending events* | Hooks load at session start | Open a **new** Claude session |
| Some sessions report, others don't | Those sessions predate the plugin | Reopen them |
| `doctor` says *state is N s stale* | Daemon isn't running | Run whichever command `doctor` prints — `sh install.sh` on a Login Items install |
| `doctor` says *N unread events* | Hooks fire but nothing drains the inbox | Same as above |
| No menu bar dot at all | Daemon died at startup | `tail ~/Library/Logs/traffic-light.log` |
| `npx` fails with *Swift is required* | No Xcode Command Line Tools | `xcode-select --install`, then re-run |
| Installer says it couldn't install the plugin | `claude` CLI missing or marketplace refused | Run the two `/plugin` lines it prints |
| Push says reachable, phone gets nothing | Check the `push topic` line in `doctor` first — it says whether messages are reaching the topic at all | If messages **are** published, the Mac is fine: check the ntfy app is subscribed to the topic shown in Settings → Notifications, that its default server matches, and that notifications are permitted |
| `push topic` shows messages, phone still silent | Phone is off your WiFi and there's no Tailscale | Install Tailscale, re-run `setup-ntfy.sh` |
| `Done` arrives without a sound | Deliberate — `Done` sends at low priority, so it lands in the shade without a banner or a chime | Raise it in `push.priorities` if you want it to announce itself |
| `setup-ntfy.sh` says Docker isn't running | Docker Desktop is closed | Start it; the container has `--restart unless-stopped` |
| Bell silent | A sound name doesn't exist | `doctor` names it; use one from `/System/Library/Sounds` |
| A session shows red for no reason | Its process died without a clean exit | That is a true red — the session really is gone |

**Screenshots of the menu bar look empty.** `screencapture` returns a wallpaper-only image when the calling process lacks Screen Recording permission, and it doesn't error. A perfectly working status item looks identical to one that never appeared. The daemon prints `statusItemButton=` and `panelVisible=` to stderr at startup so you can check without a screenshot.

## Uninstalling

```bash
npx agent-traffic-light uninstall     # or: sh install.sh uninstall
sh scripts/setup-ntfy.sh uninstall    # if you ran your own push server
```

Like the installer, it lists what it will remove and what it will leave — with
the size of each leftover — and waits for a yes. `--dry-run` and `--yes` work
here too.

It stops the daemon, removes the app bundle, the binary and the login item,
deletes the plugin folder, clears the inbox and the lock file, and takes both `traffic-light` lines
back out of your Claude Code settings. If none of that is on the machine it says
so and stops rather than asking you to confirm the removal of nothing.

Two directories are named but never touched, because Claude Code owns them:
`~/.claude/plugins/cache/traffic-light` — its own copy of the plugin, which is
what your hooks actually execute — and `~/.claude/plugins/data/traffic-light-inline`.
`claude plugin uninstall` clears its records of both; the files stay. Delete them
yourself if you want the disk back.

**Claude Code sessions you already have open keep firing the hooks** from that
cache until you restart them, so the inbox will refill once after an uninstall.
New sessions load nothing.

Config and state stay in `~/Library/Application Support/traffic-light/`. To take
those as well — including `events.jsonl`, which holds prompt and reply text if you
ever turned the debug log on:

```bash
npx agent-traffic-light uninstall --purge
```
