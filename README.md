# AgentMeter

A macOS menu-bar app showing how much of your Claude and ChatGPT rate limits you
have burned, and when each window resets. One glance instead of opening two apps.

The menu-bar dial opens a panel with one gauge per rate-limit window, each with
its percentage, a severity colour and the time it resets.

Requires macOS 13 (Ventura) or later and the Xcode Command Line Tools. Apple
Silicon and Intel are both supported; the build targets the host architecture.

## Install

```bash
git clone https://github.com/angmiayang/AgentMeter.git
cd AgentMeter
./install.sh
```

It builds from source and installs to `/Applications`. That is deliberate: a
locally built app is not quarantined by Gatekeeper, so there is no "unidentified
developer" wall and nothing to disable.

There is no permission to grant. AgentMeter reads files in your own home
directory and makes one request to Anthropic's account endpoint.

## The menu

**Refresh Now** — re-read both providers immediately.

**Open At Login** — start AgentMeter with the machine, via `SMAppService`.

**Quit AgentMeter** — stop it. Nothing is left running.

The panel above those shows each provider, its plan, and one row per window: the
percentage used, a bar, and a reset line in one grammar for both providers —
`Resets 14:30 · In 53m` when the reset is today, `Resets Tue 09:00 · In 2d 4h`
when it is further out, `Reset 14:30 · Elapsed` once the time has passed.

## How it works

| Provider | Source |
|---|---|
| ChatGPT | `~/.codex/sessions/**/rollout-*.jsonl` → `payload.rate_limits` |
| Claude | `GET api.anthropic.com/api/oauth/usage` |
| Claude fallback | `~/.claude.json` → `cachedUsageUtilization` |

Both tools already record their own limit state; there is no scraping and no API
key to supply.

It refreshes when you launch or switch to either app, when either tool writes a
log line, and hourly as a floor. The Claude request is capped at one a minute
however busy the session gets; the ChatGPT read is local and runs on a
20-second tick.

Windows are discovered rather than assumed. Claude's `limits[]` array drives one
gauge per window your plan actually has, coloured by the server's own severity
field, so a plan with weekly and Opus limits shows three gauges where a
session-only plan shows one. ChatGPT windows are named from `window_minutes`.
Plan names pass straight through from `plan_type` and `subscriptionType`, so a
plan this code has never seen still renders correctly.

**Checking costs no tokens.** ChatGPT is read entirely from logs it already
wrote, so no request leaves the machine. The Claude call hits an account usage
endpoint that reports numbers rather than generating text, so no model is
invoked. It is the same call the Claude Code client makes to fill its own cache.

## Security

This app reads credential-adjacent data, so here is its complete footprint.

- **Nothing inbound.** No server, no listening socket, no XPC service, no URL
  scheme handler. There is no code path by which anything outside your Mac can
  reach it.
- **One outbound request:** `GET https://api.anthropic.com/api/oauth/usage`. No
  other host is contacted, ever.
- **One subprocess:** `/usr/bin/security find-generic-password`, to read the
  existing `Claude Code-credentials` keychain item. Read-only, fixed arguments,
  no shell, so nothing is interpolated into a command line.
- **No dynamic code.** No `eval`, no `dlopen`, no downloaded or generated code,
  and nothing piped from `curl` in the build or install path.
- **Read-only on your data.** Never writes, moves or deletes anything under
  `~/.claude` or `~/.codex`, and never writes to the keychain.
- **No secret is stored.** The access token is read at the moment of a check,
  sent only to Anthropic in the `Authorization` header, and discarded. It is
  never logged or written to disk. `~/.codex/auth.json` is never opened.

Everything runs as you, on your machine, against your own accounts.

## Uninstall

```bash
./uninstall.sh
```

Removes the app, its preferences, saved state and caches, and the build output.
It leaves your Claude and Codex data alone, and has no keychain entry of its own
to delete.

## Caveats

**Token refresh belongs to Claude Code.** If the access token has lapsed,
AgentMeter shows `Sign-In Expired · Run: claude auth login` rather than doing a
refresh grant against a credential another app owns. Note that `claude auth
status` can report `loggedIn: true` while the *access* token is expired — the
CLI holds a valid refresh token and only exchanges it when it makes a real
request.

**A dead window shows no number.** A percentage only describes the window it was
measured in. Once the reset time has passed, that window has rolled over and the
old figure is not a smaller number but an unknown one, so the gauge greys out and
prints an em dash. This is common on the ChatGPT side, which only records a fresh
reading when it takes a turn: step away for two hours and the 5-hour figure is
genuinely unknown until your next turn.

**ChatGPT reset entitlements are not exposed.** Nothing in `~/.codex` — session
logs, desktop state, or token claims — reports how many free resets remain.

**`/api/oauth/usage` is undocumented** and may change. On failure the gauge greys
out and falls back to the local cache.

## Working on the code

```
src/main.swift        the whole application
src/makeicon.swift    renders the app icon
scripts/build.sh      compile, bundle, ad-hoc sign, optionally install
```

`./scripts/build.sh` builds into `./build` without installing.

Ad-hoc signing is all this app needs: it holds no system permission that a
re-sign would invalidate, so there is no certificate to set up.

## Licence

MIT — see [LICENSE](LICENSE). Use it, change it, ship it; keep the copyright
notice.
