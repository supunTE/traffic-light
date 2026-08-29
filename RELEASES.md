# Releases

One file per version, filed by minor. This page is the index, newest first.

Traffic Light is built on your machine rather than downloaded — see
[Quick start](README.md#quick-start). Updating is the same command as
installing.

## 1.0

- **[1.0.0](releases/1.0/1.0.0.md)** — 27 August 2026 — five signals at a
  glance, a chime on the changes that matter, push to your phone through ntfy,
  quiet hours and per-project rules, and an installer that says what it will do
  before it does it.

## How versions work

`MAJOR.MINOR.PATCH`.

- **Patch** — fixes and polish to what already exists.
- **Minor** — a new capability, or a change to how an existing one is used.
- **Major** — a break in how the tool is installed or configured: a config that
  needs rewriting, or hooks that have to be reinstalled.

Every published build gets its own number; two releases never share one.

`package.json` is the version the app is built from. `install.sh` reads it and
stamps both `Info.plist` keys, and the About page reads the version back off
the bundle — so the window cannot disagree with the app it is part of. The
release workflow checks the git tag, `v<version>`, against it.

Two other files carry the number and are kept in step by hand:
`.claude-plugin/plugin.json`, and a literal in `Version.current` that is only
ever used by the bare CLI binary, which has no bundle to ask.
