#!/bin/sh
# Traffic Light — the only code that runs inside a Claude Code session.
#
# Nothing slow or fallible runs in a hook. So this parses
# nothing, touches no network, plays no sound and holds no lock. It stamps the
# payload with an arrival time, drops it in the inbox, and exits 0 — always 0,
# even on failure, because a hook that fails must never surface as a problem in
# the session it is watching.
#
# One file per event rather than a shared append log. A `Stop` payload carries
# the entire last assistant message and can run to many kilobytes, which is far
# past the size at which concurrent appends stay atomic. Separate files cannot
# interleave and need no flock — which macOS does not ship anyway.
#
# The daemon deletes each file once ingested, and learns *which* session an
# event belongs to from the payload's own session_id, cross-referenced against
# ~/.claude/sessions/. This hook deliberately does not walk its process
# ancestry to find that out: it would cost eight `ps` forks per fire to
# discover something the daemon can read for free.

dir="${TRAFFIC_LIGHT_HOME:-$HOME/Library/Application Support/traffic-light}/inbox"
mkdir -p "$dir" 2>/dev/null || exit 0

now=$(date +%s)

# Written to a dot-file and renamed, never straight into place.
#
# `>` creates the entry before printf writes a byte, and a payload larger than
# stdio's buffer arrives in several write()s. The daemon watches this directory
# and reads on the first one, so it saw truncated JSON, failed to decode it,
# and deleted the file — losing the event permanently while the hook was still
# writing it. Measured on a real machine: five such losses in three days, every
# one an exact multiple of 1024 bytes, which is the buffer boundary. A rename
# within the same directory is atomic, so the daemon only ever sees the whole
# file or no file.
#
# The dot prefix keeps the partial out of the daemon's `*.json` enumeration
# even while it is being written. $$ is unique per fire: a single process
# cannot run two hooks at once, so no two writes can collide on this name.
tmp="$dir/.$now-$$.tmp"
printf '{"at":%s,"payload":%s}' "$now" "$(cat)" > "$tmp" 2>/dev/null &&
    mv -f "$tmp" "$dir/$now-$$.json" 2>/dev/null || rm -f "$tmp" 2>/dev/null

exit 0
