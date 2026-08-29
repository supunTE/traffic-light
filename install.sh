#!/bin/sh
# Traffic Light — build, install, and keep the daemon running.
#
# No sudo and no notarization. A locally built `Traffic Light.app` goes in
# ~/Applications and the same binary in your own ~/.local/bin, and macOS Login
# Items starts it at login — falling back to a LaunchAgent if macOS refuses the
# bundled one.
#
#   sh install.sh              build + install + start + hooks (all projects)
#   sh install.sh --local      same, but hooks only in the current directory
#   sh install.sh uninstall    stop, unload, remove
#
# Nothing is written until it has said what it will write and you have agreed.
# `--dry-run` prints that plan and stops; `--yes` skips the question for CI and
# for reinstalls; `uninstall --purge` also removes settings, state and logs.
#
# Also the implementation behind `npx agent-traffic-light`. The npm package is
# a thin wrapper around this file rather than a second copy of the logic.
set -e

repo=$(cd "$(dirname "$0")" && pwd)
bin_dir="$HOME/.local/bin"
binary="$bin_dir/traffic-light"
# A real bundle, so it has an icon, a name, and a place to be found. Built here
# rather than downloaded: a locally created .app carries no quarantine
# attribute, so Gatekeeper never inspects it and nothing needs notarizing —
# which is what avoiding notarization actually turns on.
app="$HOME/Applications/Traffic Light.app"
label="dev.supunte.traffic-light"
plist="$HOME/Library/LaunchAgents/$label.plist"
logs="$HOME/Library/Logs"
support="$HOME/Library/Application Support/traffic-light"
plugin_dir="$support/plugin"
# One source for the version, so a release is one number to change rather than
# five to remember. sed rather than jq: this script may not have jq, and the
# field is the first "version" in a file we ship ourselves.
version=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$repo/package.json" | head -1)
[ -n "$version" ] || version=0.0.0

say() { printf '  %s\n' "$1"; }

# Bold for the lines that are a decision, dim for the detail underneath a name.
# Only when stdout is a terminal: piped into a file or a CI log, escape codes
# are noise in the one place someone is reading afterwards rather than at the
# time. `NO_COLOR` is honoured because it costs one test to respect a
# convention somebody has already set for every other tool on their machine.
#
# `tput` is deliberately not used — it wants a terminfo database this script
# cannot assume exists, and these three sequences are the ones every terminal
# has agreed on for forty years.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    bold=$(printf '\033[1m'); dim=$(printf '\033[2m'); reset=$(printf '\033[0m')
else
    bold=; dim=; reset=
fi

# Between what will happen and what is happening. Without it the plan and the
# run read as one wall of text, and the moment you agreed to something is
# invisible when you scroll back.
rule() { printf '  %s%s%s\n' "$dim" "────────────────────────────────────────────────" "$reset"; }

# Flags in any order, so `uninstall --yes` and `--yes uninstall` both work.
# The old parser only looked at $1, so `install --yes` reached the switch below
# as an unknown word and was silently ignored.
#
# User scope watches every project, which is the point of the tool — one light
# for every session you have running. `--local` limits it to the current
# directory instead, which is what you want while developing Traffic Light
# itself, or to try it on one project before letting it see them all.
scope=user
action=install
assume_yes=
dry_run=
purge=

for arg in "$@"; do
    case "$arg" in
        --local|--project) scope=local ;;
        install) action=install ;;
        uninstall) action=uninstall ;;
        -y|--yes) assume_yes=yes ;;
        --dry-run) dry_run=yes ;;
        --purge) purge=yes ;;
        -h|--help)
            cat <<'USAGE'

  sh install.sh [install|uninstall] [options]

    --local, --project   hooks for this directory only, not every project
    -y, --yes            do not ask, just do it
    --dry-run            say what would happen, change nothing
    --purge              uninstall only: also delete settings, state and logs

USAGE
            exit 0 ;;
        *) echo "install.sh: unknown option: $arg" >&2; exit 2 ;;
    esac
done

# Every `[ ] && [ ] && { }` below would be a landmine under `set -e`: when the
# first test fails the whole chain returns non-zero and the script exits
# without a word. Hence `if`, everywhere, even where one line would read
# better.
if [ -n "$purge" ] && [ "$action" != uninstall ]; then
    echo "install.sh: --purge only applies to uninstall" >&2
    exit 2
fi

# The same script is reached two ways and the undo line has to name the one
# the reader actually used. `bin/cli.js` sets this.
if [ -n "${TRAFFIC_LIGHT_VIA_NPX:-}" ]; then
    undo="npx agent-traffic-light uninstall"
else
    undo="sh install.sh uninstall"
fi

# The Distress Call needs Claude to know it exists.
#
# Everything else here is wiring the daemon can do on its own: the hooks fire
# whether or not anyone knows about them. This one cannot. `traffic-light
# broken` is the only route to a red light that carries a reason, and the only
# one Claude has to choose to call — so if nothing ever tells it the command is
# there, the feature ships and never runs.
#
# `~/.claude/CLAUDE.md` is where Claude reads standing instructions for every
# project, which is why it goes there rather than into one repo. It is also a
# file the user writes by hand, so this is asked separately from the install
# and is never assumed: an installer that edits your instructions to Claude
# without asking has overstepped, however useful the edit.
claude_md="$HOME/.claude/CLAUDE.md"
tl_begin="<!-- traffic-light:distress-call -->"
tl_end="<!-- /traffic-light:distress-call -->"

distress_note() {
    cat <<NOTE
$tl_begin
## Traffic Light — calling for help

If you become genuinely stuck — the same error three times, a credential you
cannot ask for, a loop you cannot break out of — run:

    traffic-light broken "<one sentence on what is wrong>"

This turns the user's status light red with your reason, so they know to come
back and what for. Nothing else can report this: every other state is inferred
from hooks, and a session going round in circles looks exactly like one making
progress.

Use it sparingly. Not for an ordinary failure you are still working through —
a light that cries wolf is worse than no light. Answering you clears it; there
is no second command to run.
$tl_end
NOTE
}

has_distress_note() {
    [ -f "$claude_md" ] && grep -qF "$tl_begin" "$claude_md"
}

# Drops the block, and any blank lines left at the end of the file with it.
# Without the trim, each re-run of the installer leaves one more blank line
# behind than the last — a file that grows a little every time you reinstall.
strip_distress_note() {
    [ -f "$claude_md" ] || return 0
    awk -v b="$tl_begin" -v e="$tl_end" '
        index($0,b){skip=1}
        !skip{ if ($0 == "") { blank++ } else { while (blank-- > 0) print ""; blank=0; print } }
        index($0,e){skip=0}
    ' "$claude_md" > "$claude_md.tl" && mv "$claude_md.tl" "$claude_md"
}

add_distress_note() {
    mkdir -p "$(dirname "$claude_md")"
    # Stripped first rather than appended to, so re-running the installer
    # updates the wording in place instead of stacking a second copy.
    strip_distress_note
    [ -s "$claude_md" ] && printf '\n' >> "$claude_md"
    distress_note >> "$claude_md"
}

remove_distress_note() {
    has_distress_note || return 0
    strip_distress_note
}

# Asked on /dev/tty, never on stdin. Under `npx` stdin is not reliably the
# terminal, so a plain `read` either blocks for ever or reads nothing and
# takes the silence for an answer. If there is no terminal at all — CI, a
# pipe, a hook — this refuses rather than assuming yes.
# A path as a human should read it. Same reason the daemon does this: installer
# output is pasted into bug reports, and the absolute form carries the account
# name. Matched on `$HOME/` so a sibling directory whose name merely starts the
# same way is left alone.
tilde() {
    case "$1" in
        "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;;
        *)         printf '%s' "$1" ;;
    esac
}

confirm() {
    if [ -n "$assume_yes" ]; then return 0; fi
    if ! { exec 3</dev/tty; } 2>/dev/null; then
        printf '\n  No terminal to ask on. Re-run with --yes to go ahead.\n\n' >&2
        exit 1
    fi
    printf '  %s%s%s [y/N] ' "$bold" "$1" "$reset"
    reply=
    read -r reply <&3 || reply=
    exec 3<&-
    printf '\n'
    case "$reply" in
        [yY]|[yY][eE][sS]) return 0 ;;
    esac
    printf '  Nothing was changed.\n\n'
    # Non-zero, so `npx … install && something-else` does not run the
    # something-else after you said no.
    exit 1
}

# Real numbers, read at the moment of asking. A plan that says "some files"
# is not a plan.
size_of() {
    if [ -e "$1" ]; then
        du -sh "$1" 2>/dev/null | awk '{print $1}'
    else
        printf -- '-'
    fi
}

# Only what is actually there. The first version listed all five leftovers
# with a dash beside the absent ones, and a plan that names files which do not
# exist is a plan you start reading past.
kept_row() {
    if [ -e "$2" ]; then
        printf '    %-18s %s%5s%s   %s\n' "$1" "$dim" "$(size_of "$2")" "$reset" "$3"
        any=yes
    fi
}

kept_rows() {
    any=
    kept_row "config.json" "$support/config.json" "your settings"
    kept_row "state.json" "$support/state.json" "the sessions it last saw"
    kept_row "projects.json" "$support/projects.json" "projects you have named"
    kept_row "events.jsonl" "$support/events.jsonl" "debug log, off by default"
    kept_row "traffic-light.log" "$logs/traffic-light.log" "daemon output"
    [ -n "$any" ]
}

# Same rule for the other half of the plan. The two trailing lines are not
# files, so they are only worth saying when something is installed to detach
# them from.
removal_rows() {
    found=
    installed=
    if [ -e "$binary" ]; then
        printf '    %s\n' "~/.local/bin/traffic-light"; installed=yes
    fi
    if [ -d "$app" ]; then
        printf '    %s\n' "~/Applications/Traffic Light.app"; installed=yes
    fi
    if [ -d "$plugin_dir" ]; then
        printf '    %s\n' "~/Library/Application Support/traffic-light/plugin"; installed=yes
    fi
    # Only the marked block, never the file. Everything else in CLAUDE.md is
    # the user's own writing and none of our business.
    if has_distress_note; then
        printf '    %s\n' "~/.claude/CLAUDE.md   the Distress Call block only"; installed=yes
    fi
    if [ -f "$plist" ]; then
        printf '    %s\n' "~/Library/LaunchAgents/$label.plist"; installed=yes
    fi
    # Our own scratch, and worth nothing without a daemon: the inbox is a
    # letterbox nobody is left to empty, and daemon.lock is an empty file whose
    # only purpose is to hold a kernel lock that died with the process. They
    # used to survive a plain uninstall because they sit in the directory that
    # holds your settings — a rule written for config.json, applied to a whole
    # folder. They are not your settings, so they go.
    if [ -d "$support/inbox" ]; then
        printf '    %s   %s%s%s\n' "~/Library/Application Support/traffic-light/inbox" \
            "$dim" "$(size_of "$support/inbox")" "$reset"
        found=yes
    fi
    if [ -e "$support/daemon.lock" ]; then
        printf '    %s\n' "~/Library/Application Support/traffic-light/daemon.lock"
        found=yes
    fi
    if [ -n "$installed" ]; then
        printf '    %s\n' "the Login Items entry"
        printf '    %s\n' "both traffic-light lines in your Claude Code settings"
        found=yes
    fi
    [ -n "$found" ]
}

# Claude Code's own directories. It created them when we asked it to install
# the plugin, and `claude plugin uninstall` — which this script runs — clears
# its records but leaves the files. Reaching into another tool's cache to
# delete things could break its bookkeeping, so this script does not. Saying
# nothing about hook scripts that still exist is the worse option, though, so
# they are named and left to you.
their_row() {
    if [ -e "$2" ]; then
        printf '    %-42s %s%5s%s   %s\n' "$1" "$dim" "$(size_of "$2")" "$reset" "$3"
        any=yes
    fi
}

theirs_rows() {
    any=
    their_row "~/.claude/plugins/cache/traffic-light" \
        "$HOME/.claude/plugins/cache/traffic-light" "its copy of the plugin"
    their_row "~/.claude/plugins/data/traffic-light-inline" \
        "$HOME/.claude/plugins/data/traffic-light-inline" "an older inline copy"
    [ -n "$any" ]
}

install_plan() {
    if [ "$scope" = local ]; then
        where="for this directory only"
        settings="this project's .claude settings"
    else
        where="for every project"
        settings="~/.claude/settings.json, your user settings"
    fi
    cat <<PLAN

  Traffic Light $version  .  install

  Built from source on this Mac. Nothing is downloaded, nothing runs as
  root, and you will not be asked for a password.

  Files it will create

    $dim~/.local/bin/traffic-light$reset                   the command line tool
    $dim~/Applications/Traffic Light.app$reset             the daemon, with an icon
    $dim~/Library/Application Support/traffic-light$reset  hooks, settings, state
    $dim~/Library/Logs/traffic-light.log$reset             what the daemon prints

  What it will do

    1  compile the daemon        swift build, about a minute
    2  sign the app              ad-hoc signature, offline, no account
    3  run it now, and at login  through macOS Login Items
    4  install the Claude Code hooks, $where

  Step 4 goes through the claude CLI; this script never edits your settings
  itself. Two lines are added to $settings —
  not the hooks themselves, which stay in the folder above:

    extraKnownMarketplaces  traffic-light
    enabledPlugins          traffic-light@traffic-light

  To undo all of it

    $undo

PLAN
}

# Named, never touched. The heading says whose they are, because "left behind"
# and "not ours to delete" are different things and the reader deserves to know
# which one this is.
theirs_section() {
    if theirs_rows >/dev/null; then
        printf '\n  Left for you, if you want them gone — Claude Code owns these\n\n'
        theirs_rows
        printf '\n    Sessions you already have open keep running the hooks from that\n'
        printf '    cache until you restart them. New sessions will not.\n'
    fi
}

uninstall_plan() {
    printf '\n  Traffic Light  .  uninstall\n\n  Will be removed\n\n'
    removal_rows || printf '    nothing — the app and the hooks are already gone\n'
    printf '\n'
    if [ -n "$purge" ]; then
        printf '  Will also be removed, because of --purge\n\n'
    else
        printf '  Will be kept\n\n'
    fi
    if ! kept_rows; then
        printf '    nothing — no settings, state or logs on this Mac\n'
        theirs_section
        return 0
    fi
    if [ -z "$purge" ]; then
        # The warning only when there is something to warn about.
        if [ -e "$support/events.jsonl" ]; then
            cat <<PLAN

    events.jsonl holds your prompt and reply text if you ever turned the
    debug log on. Remove all of these too with:

      $undo --purge
PLAN
        else
            cat <<PLAN

    Remove these too with:

      $undo --purge
PLAN
        fi
    fi
    theirs_section
    printf '\n'
}

if [ "$action" = uninstall ]; then
    # Nothing here at all: say so and stop, rather than asking someone to
    # confirm the removal of a list of things that do not exist.
    if ! removal_rows >/dev/null && ! kept_rows >/dev/null; then
        printf '\n  Traffic Light is not installed.\n\n'
        exit 0
    fi
    uninstall_plan
    if [ -n "$dry_run" ]; then exit 0; fi
    confirm "Continue?"
    rule

    [ -x "$app/Contents/MacOS/traffic-light" ] &&
        "$app/Contents/MacOS/traffic-light" login-item unregister 2>/dev/null || true
    launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
    # bootout only reaches a job launched under $label, and the happy path
    # starts the daemon with `open -a`, which is not one. Without this the
    # daemon kept running until logout — menu bar item and all — with its own
    # bundle deleted out from under it.
    pkill -f "$app/Contents/MacOS/traffic-light" 2>/dev/null || true
    sleep 1
    rm -f "$plist" "$binary"
    rm -rf "$app"
    # Deregistered before the directory it points at is deleted, or a live
    # Claude Code session is left pointing at a folder that no longer exists.
    if command -v claude >/dev/null 2>&1; then
        claude plugin uninstall traffic-light@traffic-light >/dev/null 2>&1 || true
        claude plugin marketplace remove traffic-light >/dev/null 2>&1 || true
    fi
    rm -rf "$plugin_dir"
    remove_distress_note
    # Ours, and useless without a daemon — see removal_rows for why these are
    # not held back behind --purge like config.json is.
    rm -rf "$support/inbox"
    rm -f "$support/daemon.lock"

    if [ -n "$purge" ]; then
        rm -rf "$support"
        rm -f "$logs/traffic-light.log"
        say "Removed, including your settings, state and logs."
    else
        say "Removed."
        # Only when something is actually there. Saying "settings are still in"
        # and naming an empty directory is the same lie as listing files that
        # do not exist, arriving one line later.
        if kept_rows >/dev/null; then
            say "Settings and state are still in $(tilde "$support")"
        fi
    fi
    if theirs_rows >/dev/null; then
        say ""
        say "Restart any open Claude Code session: it still runs the hooks from"
        say "Claude Code's own cache until it does."
    fi
    exit 0
fi

case "$(uname -s)" in
    Darwin) ;;
    *) echo "Traffic Light is macOS only." >&2; exit 1 ;;
esac

if ! command -v swift >/dev/null 2>&1; then
    cat >&2 <<'MISSING'
Swift is required to build the daemon, and it was not found.

It ships with Xcode's Command Line Tools — you do not need full Xcode:

    xcode-select --install

Then run this again.
MISSING
    exit 1
fi

# Shown after the platform and toolchain checks, so an unsupported Mac fails
# on the real reason rather than after a wall of text describing an install
# that was never going to happen.
install_plan
if [ -n "$dry_run" ]; then exit 0; fi
confirm "Continue?"
rule

# Captured, not streamed. `swift build` prints every compiler warning with
# three lines of source context each, so agreeing to install was answered with
# forty lines of yellow — which reads as something having gone wrong at exactly
# the moment someone has decided to trust this. The warnings it printed were
# real and are fixed, but that is not the point: the next toolchain will have
# its own, and none of them are the installing reader's business unless the
# build actually fails.
say "Building… (about a minute the first time)"
build_log="${TMPDIR:-/tmp}/traffic-light-build.$$.log"
if ! swift build -c release --package-path "$repo/daemon" >"$build_log" 2>&1; then
    printf '\n  The build failed, so nothing has been installed. Output:\n\n' >&2
    sed 's/^/    /' "$build_log" >&2
    printf '\n' >&2
    rm -f "$build_log"
    exit 1
fi
rm -f "$build_log"

mkdir -p "$bin_dir" "$logs"
# Copy then rename, never write in place: overwriting a running executable
# truncates the file the kernel is paging from and the daemon dies with
# SIGKILL. A rename swaps the directory entry and leaves the old inode alone
# until the running process exits.
cp "$repo/daemon/.build/release/traffic-light" "$binary.new"
mv -f "$binary.new" "$binary"
say "Installed $binary"

# The bundle. The same binary, in a place with a name and an icon — Spotlight,
# Launchpad, and the Applications folder all look here and nowhere else.
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
# Copy then rename here too. The daemon is still running from this exact
# path — it is not stopped until the pkill further down — and macOS returns
# ETXTBSY for a write to a running Mach-O, so `cp` over it fails outright
# under `set -e` and leaves a half-built bundle. Same discipline as $binary
# above.
cp -f "$binary" "$app/Contents/MacOS/traffic-light.new"
mv -f "$app/Contents/MacOS/traffic-light.new" "$app/Contents/MacOS/traffic-light"

# Held in its own variable and checked: `rm -rf "$iconset_tmp"` is
# `rm -rf /` if mktemp ever returns empty.
iconset_tmp=$(mktemp -d)
[ -n "$iconset_tmp" ] && [ -d "$iconset_tmp" ] || { echo "mktemp failed" >&2; exit 1; }
iconset="$iconset_tmp/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 64 128 256 512; do
    # `|| true`: twelve chances for the just-built binary to abort the whole
    # installer with its output discarded, before the app is signed or the
    # hooks are installed. An icon is not worth the install.
    "$binary" icon "$iconset/icon_${size}x${size}.png" "$size" >/dev/null 2>&1 || true
    "$binary" icon "$iconset/icon_${size}x${size}@2x.png" "$((size * 2))" >/dev/null 2>&1 || true
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns" 2>/dev/null || true
rm -rf "$iconset_tmp"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Traffic Light</string>
    <key>CFBundleDisplayName</key><string>Traffic Light</string>
    <key>CFBundleIdentifier</key><string>$label</string>
    <key>CFBundleExecutable</key><string>traffic-light</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>$version</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <!-- An agent, not an app with windows: no Dock icon until Settings opens,
         which is what the .accessory activation policy already does. -->
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# KeepAlive only on a *crash*. Plain `true` was the first version, and it made
# "Quit Traffic Light" a lie: the menu item exited cleanly, launchd relaunched
# within the second, and the light came straight back. SuccessfulExit false
# keeps the original intent — the daemon holds no state worth protecting, so a
# crash should always be recovered — while letting a deliberate quit stand
# until the next login.
#
# The agent plist lives *inside* the app. That is the whole difference in how
# System Settings names this: a loose plist in ~/Library/LaunchAgents is
# attributed to the executable it points at, so the Login Items row reads
# "traffic-light" with a generic icon. Registered from within the bundle, the
# row carries the app's name and icon instead.
#
# BundleProgram, not Program: the path is relative to the bundle, so moving the
# app to /Applications does not break it.
mkdir -p "$app/Contents/Library/LaunchAgents"
cat > "$app/Contents/Library/LaunchAgents/$label.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$label</string>
    <key>BundleProgram</key><string>Contents/MacOS/traffic-light</string>
    <key>ProgramArguments</key>
    <array>
        <string>Contents/MacOS/traffic-light</string>
        <string>daemon</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key>
    <dict><key>SuccessfulExit</key><false/></dict>
    <key>StandardOutPath</key><string>$logs/traffic-light.log</string>
    <key>StandardErrorPath</key><string>$logs/traffic-light.log</string>
</dict>
</plist>
PLIST

# Signed *after* the bundled LaunchAgent plist is written, and that order is
# the whole point.
#
# `SMAppService` will not load an agent plist the app's signature does not
# cover. Writing the plist after signing left it out of the sealed resources,
# so a first install failed with `Codesigning failure loading plist … -67054`
# and fell back to a loose LaunchAgent — a Login Items row with a generic name
# and icon instead of the app's.
#
# It shows only on a genuinely fresh install, or one after `uninstall`, which
# deletes the bundle: a *re*install signs the previous run's plist, already
# sitting in the bundle, so running the installer twice masks it.
#
# `codesign -v` was not enough to catch this. It reported the bundle valid
# while `_CodeSignature/CodeResources` listed no LaunchAgents entry at all.
codesign --force --deep --sign - "$app" >/dev/null 2>&1 || true
say "Installed $app"

launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true

# Stop whatever is already running, or an update installs nothing.
#
# `bootout` only reaches a job launched under $label. An instance the login
# item started sits under `application.dev.supunte.traffic-light.<hash>`, and
# one started by `open` is not a launchd job at all — so the old binary
# survived, and the singleton lock then made the new one exit on the spot. The
# result was an installer that copied a fresh build, printed "Daemon running",
# and left the previous one owning the status item. The failure is silent.
pkill -f "$app/Contents/MacOS/traffic-light" 2>/dev/null || true
# Let the lock be released before anything tries to take it.
sleep 1

# Registered by the app through SMAppService, which is what makes System
# Settings attribute the Login Items row to the bundle — name and icon — rather
# than to the executable the old loose plist pointed at.
#
# With a fallback, because SMAppService is documented for signed apps and this
# one is ad-hoc. A row that looks wrong is a blemish; a light that does not come
# back at login is a broken tool, so the old arrangement stays as the safety net.
#
# stderr captured rather than streamed, like the build above: the binary
# prints the raw `SMAppService` error, and unindented in the middle of the
# install it reads as a crash rather than as the note that precedes a working
# fallback. Kept and shown under the fallback line, where it is context.
login_log="${TMPDIR:-/tmp}/traffic-light-login.$$.log"
# stdout is discarded, not just stderr. `register` prints its own one-line
# result, which arrives unindented in the middle of an otherwise aligned run
# and reads as something having gone wrong. The status is asked for on the very
# next line and reported through `say` like everything else.
if "$app/Contents/MacOS/traffic-light" login-item register >/dev/null 2>"$login_log"; then
    state=$("$app/Contents/MacOS/traffic-light" login-item status || true)
    # Registering a login item does not start one, so this asks rather than
    # assuming — printing "Daemon running" over a daemon that is not running is
    # the failure to avoid.
    if ! pgrep -f "$app/Contents/MacOS/traffic-light" >/dev/null 2>&1; then
        open -a "$app" 2>/dev/null || true
        sleep 1
    fi
    rm -f "$login_log"
    case "$state" in
        enabled) say "Daemon running, and will start at login." ;;
        *approval*)
            say "Daemon installed. macOS wants you to approve it:"
            say "    System Settings -> General -> Login Items"
            ;;
        *) say "Daemon installed, login item is $state" ;;
    esac
else
    say "macOS refused the bundled login item; using a LaunchAgent instead."
    if [ -s "$login_log" ]; then sed 's/^/      /' "$login_log"; fi
    cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>$app/Contents/MacOS/traffic-light</string>
        <string>daemon</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key>
    <dict><key>SuccessfulExit</key><false/></dict>
    <key>StandardOutPath</key><string>$logs/traffic-light.log</string>
    <key>StandardErrorPath</key><string>$logs/traffic-light.log</string>
</dict>
</plist>
PLIST

    # `bootout` returns before launchd has finished tearing the job down, and a
    # `bootstrap` that lands inside that window fails with a bare "Input/output
    # error". Retry, then say something useful rather than an errno.
    bootstrapped=
    for _ in 1 2 3 4 5; do
        if launchctl bootstrap "gui/$(id -u)" "$plist" >/dev/null 2>&1; then
            bootstrapped=yes
            break
        fi
        sleep 1
    done
    if [ -n "$bootstrapped" ]; then
        say "Daemon running, and will start at login."
    else
        say "Could not start the daemon. It is installed; start it with:"
        say "    launchctl bootstrap gui/$(id -u) $(tilde "$plist")"
    fi
fi

# The hooks, as a Claude Code plugin — never a merge into settings.json.
#
# Installed from a copy under Application Support rather than from this
# directory. Run via npx, "this directory" is a cache npm may clear at any
# time, and a marketplace pointing into a deleted folder is worse than no
# marketplace at all. The copy also means no network and no pushed repo are
# needed for the hooks to work.
#
# Deregistered *before* the directory it points at is deleted. The other way
# round leaves any live Claude Code session pointing at a folder that no
# longer exists.
if command -v claude >/dev/null 2>&1; then
    claude plugin marketplace remove traffic-light >/dev/null 2>&1 || true
fi
rm -rf "$plugin_dir"
mkdir -p "$plugin_dir"
cp -R "$repo/.claude-plugin" "$repo/hooks" "$plugin_dir/"

if command -v claude >/dev/null 2>&1; then
    if claude plugin marketplace add "$plugin_dir" --scope "$scope" >/dev/null 2>&1 \
       && claude plugin install traffic-light@traffic-light --scope "$scope" >/dev/null 2>&1; then
        say "Hooks installed."
    else
        say "Could not install the plugin automatically. In Claude Code, run:"
        say "    /plugin marketplace add $plugin_dir"
        say "    /plugin install traffic-light@traffic-light"
    fi
else
    say "The claude CLI was not found, so the hooks are not installed. In Claude Code:"
    say "    /plugin marketplace add $plugin_dir"
    say "    /plugin install traffic-light@traffic-light"
fi

# Asked here rather than in the plan: it is a separate decision about a file
# this script does not otherwise touch, and the install is already complete and
# useful without it.
if [ -n "$dry_run" ]; then
    say "Would offer to add the Distress Call instruction to ~/.claude/CLAUDE.md."
elif [ -n "$assume_yes" ]; then
    # --yes is for CI and reinstalls. Appending to a file the user writes by
    # hand is not something to do on an assumed answer, so it is skipped and
    # said out loud rather than done quietly.
    say "Skipped the Distress Call instruction — re-run without --yes to add it."
else
    cat <<'ASK'

  One more thing, separately.

  `traffic-light broken "<reason>"` turns your light red with a reason. It is
  the only signal Claude has to volunteer — every other one is read from hooks.
  But nothing tells Claude the command exists, so it will never use it.

  This adds a short paragraph to ~/.claude/CLAUDE.md, in a marked block that
  `uninstall` takes back out. It applies to every project.

ASK
    if [ -n "$assume_yes" ] || { printf '  %sAdd it?%s [y/N] ' "$bold" "$reset"; reply=; exec 3</dev/tty 2>/dev/null \
        && read -r reply <&3 && exec 3<&- ; printf '\n'; case "$reply" in [yY]|[yY][eE][sS]) true ;; *) false ;; esac; }; then
        add_distress_note
        say "Added to ~/.claude/CLAUDE.md."
    else
        say "Left alone. Add it later by re-running the installer."
    fi
fi

case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) echo ""; say "Note: $bin_dir is not on your PATH."
       say "Add it to use \`traffic-light status\` and \`traffic-light preview\`." ;;
esac

cat <<'NEXT'

  Hooks load when a session starts, so open a new session — or restart Claude.
  Then check everything landed:

      traffic-light doctor

NEXT
