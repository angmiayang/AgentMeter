# AgentMeter

*Rate-limit meter for Claude and ChatGPT, in the macOS menu bar.*

How much of your Claude and ChatGPT rate limits you have burned, and when each
window resets — one glance instead of opening two apps.

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

## Keeping the Claude gauge alive

Claude Code's access token lapses within hours, and it is only renewed when the
**CLI itself** makes a request. Work in the Claude desktop app all day and that
token goes stale, so the gauge greys out with `Sign-In Stale`. Your login is
fine — the refresh token is good for weeks — only the short-lived half has died.

To refresh it, run the CLI and ask it for your usage:

```bash
claude
```

then type `/usage`. That call goes through the same endpoint AgentMeter uses, so
it forces the token exchange without spending any inference tokens. Reopen
AgentMeter and the gauge fills in.

A long-lived token from `claude setup-token` **does not work here.** It is scoped
for inference only, and the usage endpoint rejects it:

```
GET /api/oauth/usage   403  OAuth token does not meet scope requirement user:profile
GET /v1/models         200
```

So there is no way to keep the Claude gauge alive indefinitely without the CLI
being used. The ChatGPT side has no such dependency.

## Security

This app reads credential-adjacent data, so here is its complete footprint.

- **Nothing inbound.** No server, no listening socket, no XPC service, no URL
  scheme handler. There is no code path by which anything outside your Mac can
  reach it.
- **One outbound request:** `GET https://api.anthropic.com/api/oauth/usage`. No
  other host is contacted, ever.
- **One subprocess:** `/usr/bin/security find-generic-password`, to read the
  existing `Claude Code-credentials` keychain item. Read-only, fixed arguments,
  no shell, so nothing is interpolated into a command line. It never *writes* to
  the keychain, and creates no keychain item of its own.
- **No dynamic code.** No `eval`, no `dlopen`, no downloaded or generated code,
  and nothing piped from `curl` in the build or install path.
- **Read-only on your data.** Never writes, moves or deletes anything under
  `~/.claude` or `~/.codex`, and never writes to the keychain.
- **No secret is stored by the app.** Whichever token is in play is read at the
  moment of a check, sent only to Anthropic in the `Authorization` header, and
  discarded. It is never logged or written to disk. `~/.codex/auth.json` is
  never opened.

Everything runs as you, on your machine, against your own accounts.

## Uninstall

```bash
./uninstall.sh
```

Removes the app, its preferences, saved state and caches, and the build output.
It leaves your Claude and Codex data alone, and has no keychain entry of its own
to delete.

## Caveats

**The Claude gauge depends on the CLI being used.** See "Keeping the Claude
gauge alive" above. AgentMeter will not refresh Claude Code's credential itself:
if Anthropic rotates refresh tokens on exchange, doing so would either discard
the replacement and log you out of Claude Code, or race Claude Code for the same
keychain entry. Neither is worth it for a status widget.

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
