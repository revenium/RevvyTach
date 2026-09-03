# RevvyTach — Product Promise

> **Draft for owner review.** Drafted by an agent from the README, changelog, roadmap and source on 2026-09-03. The bug-hunt and dream loops (see `revvie-sdlc/project-documentation/agent-loops/`) read this file as ground truth. Edit freely, resolve every `[confirm]` marker, then merge to `main` to switch the loops on for this repo.


## The promise

When I hit a Claude or Codex limit, I can see at a glance which of my accounts still has headroom and put my terminal on it in one click — without browser tabs, re-logins, or handing my credentials to anyone.

## Who it is for

**Primary:** developers on macOS 14+ running **two or more subscription accounts** (topping out around ten for nearly everyone, with no hard limit by design) across Claude (Pro/Max/Team/Enterprise seats) and/or ChatGPT-via-Codex, mixed but biased toward Claude, working in the `claude`/`codex` CLIs, often in tmux. The CHANGELOG's reference machine has seven profiles. Many already run a menu bar manager (Ice, Thaw, Bartender…).

**Also first-class (owner, 2026-09-03):** Team/Enterprise members who need *their own* extra-usage spend separated from the org's (4.0.6). Org-versus-member correctness ranks with personal Max/Pro correctness, not below it.

**Secondary:** people also tracking Anthropic Console spend; non-English users (9 locales); Remote Desktop/headless Macs; automation users (auto-switch, auto-start on reset).

**NOT for** (README, verbatim intent): one Claude account wanting the 5-hour window in the menu bar — "so would something simpler." Also not: Codex API-key/Bedrock accounts, OpenAI Platform billing, Windows/Linux, macOS < 14.

## Jobs to be done

1. **At the limiter, find headroom.** Hit a 5-hour/weekly limit → need the next account now → all accounts' session + weekly % side by side. *Multi-item menu bar, popover Accounts list, `+N` overflow, pace markers.*
2. **Move the terminal with me.** Picked an account → `claude`/`codex` should use it without re-login → Make Active rewrites `CLAUDE_CONFIG_DIR`/`CODEX_HOME` pointers and tmux env. *Claude Code linking (`~/.claude-accounts/`), Codex home linking, rc snippet.*
3. **Look without touching.** Mid-task, curious about another account → must not yank the running CLI → click = view, Make Active = switch (also via right-click, 4.2.0).
4. **Get warned before redline.** Burning fast → know before the wall → thresholds, pace markers, notifications, auto-switch to next profile with room, auto-start on reset (Claude only).
5. **Trust the numbers and trust the app with my keys.** Two sign-ins per Claude profile each expire → numbers honest ("—" not "0%"), broken credential named, secrets never leave the Keychain. *Two-strike auth verdict, red/amber marks, fail-closed store, Codex process boundary.*
6. **Keep accounts consistent.** MCP server added under one account → present everywhere → MCP union-merge, skills symlink sync (Claude only).
7. **Coexist with a crowded menu bar.** Six items plus a manager → nothing hidden or stranded → automatic overflow, manager detection standing down, arrangement persisted.

## Core features that carry the promise

| Feature | What it does | JTBD | Symptom if broken |
|---|---|---|---|
| Claude usage read | Session/weekly/per-model % via Claude Code OAuth (`api.anthropic.com/api/oauth/usage`); org figures via `claude.ai/api/organizations/{id}/usage` + `overage_*` | 1, 5 | Wrong/frozen %, confident 0%, org spend shown as mine |
| Claude Code token renewal + write-back | Refreshes the CLI's OAuth token (`platform.claude.com/v1/oauth/token`) and writes the rotated token back into Claude Code's own credential | 2, 5 | `claude` demands login for an account never signed out |
| Codex usage read | Bounded `codex app-server` process; `account/rateLimits/read` etc. | 1, 5 | Codex profiles blank/"unsupported"; hung process |
| Make Active (one slot per provider) | Writes `.last-account`/`.last-codex-home`, `tmux set-environment` | 2, 3 | New terminal on wrong account; `CODEX_HOME` on a dead path |
| Auth-state verdict | Expired vs. not-permitted vs. offline; names the failing sign-in | 5 | False "sign in again," or silent stale numbers |
| Multi-item menu bar + overflow + manager detection | One item per profile; `+N` only with truly no room; stands down under a manager | 1, 7 | Accounts hidden, items off-screen, manager UI locks |
| Keychain store (fail-closed) | Login Keychain; memory-only if refused; plaintext migrated out | 5 | Cleartext key on disk; login deleted on switch |
| Notifications / auto-switch / auto-start | Threshold alerts; switch to next profile with room; new session on reset | 4 | "Session reset" spam; silent limit hit |
| Sparkle update + DMG | Signed, notarized, Ed25519 feed; legacy copy for pre-rename installs | all | "Improperly signed" update; unlaunchable build |
| Usage history + export | Bounded per-profile JSON, charts, CSV/JSON | 4 | 20 MB files of unreadable records |

## Non-goals and deliberate omissions

- No telemetry, analytics, crash reporting, cloud sync, or third-party services.
- Never reads/copies/logs `CODEX_HOME/auth.json` or any Codex token; never bundles the Codex CLI.
- Never edits shell rc files, `settings.json`, or Codex files; the snippet is copy-only.
- Today: never reads Chrome cookies/login DBs; Chrome-assisted setup reads profile labels only. **Not a permanent non-goal.** The owner would welcome reading the claude.ai session key from Chrome with explicit, clearly disclosed user permission, because it would make setup far easier. The dream loop may propose it; any brief must cover the consent flow, what is read and when, and the changes to `docs/data-and-privacy.md`.
- Read-only: cannot send messages, spend credits, or redeem Codex reset credits.
- No OpenAI Platform billing; no Codex API-key/Bedrock accounts.
- Removed on purpose: header account dropdown (3.1.0); Claude Code statusline integration (3.2.0 — the platform does it natively).
- No XPC helper, persistent process pool, database, or plugin framework (decision log).

## Failure modes users tolerate least

Ranked by how directly they void the promise. **(U)** = triggered by an upstream Anthropic/OpenAI change, not app logic.

1. **A confident wrong number.** 0% for an unmeasured window (4.0.10); 0% for a model with no allowance (4.2.0 U); org spend under a member's own bars — "$2,593.16 that was not his" (4.0.6); a signed-out account showing yesterday's figures because claude.ai answers "not permitted," not "not signed in" (4.2.0 U); no staleness cue (4.0.8).
2. **Breaking the user's CLI login.** Refresh-token rotation leaving `claude` with a spent token (4.0.10 U); login deleted before rewrite (3.3.7); a profile absorbing another account's sign-in (4.0.7); `CODEX_HOME` stranded on a deleted/unmounted path (3.4.0); test suite rewriting real Codex config (3.4.0).
3. **Auth alarms wrong in either direction.** Telling a signed-in account to sign in — Claude Code rotates tokens on its own schedule (4.0.7 U); one refused request flagging a healthy profile (4.1.2); "expired" naming the wrong sign-in (4.0.7); Settings "Fully set up" while the icon is red (4.2.0).
4. **Can't launch or update.** 3.3.0 unlaunchable (Keychain entitlement); 4.0.2 Sparkle "improperly signed" after the rename; 4.0.3 stuck at old path.
5. **Menu bar manager conflicts.** Items stranded off-screen (3.2.1); managers unable to move items, rearrange UI freezing (3.3.3); arrangement lost on quit (3.3.4); collapsing under a manager (3.3.3).
6. **Waste and crashes.** History 97% unreadable, 20 MB+ (3.3.5/6); refresh multiplying after remote reconnect (3.3.2); popover crash on resize (4.0.7).
7. **Notification noise.** "Session reset" firing when nothing reset — Claude re-anchors the window to the first message (3.2.1 U).

The upstream class recurs and users cannot fix it: token rotation, 401-vs-403 meaning, empty-vs-zero fields, `overage_*` behaviour, Codex app-server protocol shape, Chrome `Local State` format.

## Constraints and risks for new features

- **Undocumented upstream surfaces:** `claude.ai/api/organizations/*` (usage, `overage_spend_limit`, `overage_credit_grant`), `api.anthropic.com/api/oauth/{usage,profile}`, `platform.claude.com/v1/oauth/token` with Claude Code's client ID, Claude Code's Keychain item + `.credentials.json` (read via `/usr/bin/security` because the ACL trusts that binary), Codex app-server JSONL methods. Any can change in a CLI release. New fields must degrade to "unavailable," never zero.
- **Platform:** macOS 14+, universal binary; shipped builds use the *login* Keychain (data-protection path withdrawn in 3.3.1); Carbon hotkeys; Accessibility re-prompts when the app path changes.
- **Distribution:** Developer ID + notarization + stapling of app *and* DMG, Revenium Ed25519 Sparkle key, Homebrew cask token **expires 2027-08-03**, monotonically increasing build number, legacy `Claude Usage.app` copy must stay in the DMG for 3.x updaters. Release needs the credential-holding workstation.
- **Localization:** 9 locales × 1,127 keys; `validate_localizations.sh` is a hard gate, plus fit tests (Japanese clipped in 4.0.8). Every UI string costs nine translations.
- **Security posture:** no secrets in logs/diagnostics (`SensitiveDataRedactor`, serialization-guard tests), no plaintext fallback, no `auth.json` access, tests must not touch the developer's real Keychain/Codex config.
- **Concurrency:** refresh is an actor keyed by profile UUID; profiles sharing one Claude Code login need independent retries (4.0.7). Cross-profile races are a proven bug source.
- **Labs status:** best-effort beta, no SLA, support via Discord/GitHub.

## Competitive context

The cheapest alternative is nothing: Claude Code's statusline already exposes `rate_limits.five_hour`/`seven_day`, which is why RevvyTach dropped its own. Single-account menu bar widgets — including the upstream Claude Usage Tracker forked at 3.0.3 — cover "one account, one gauge." CodexBar `[confirm]` is the closest peer: a menu bar usage tracker covering Codex and Claude, but as far as read `[confirm]` it does not switch the CLI's active credentials or manage per-account config directories. RevvyTach bets on the painful end: many accounts, two providers, one active slot each, the terminal following via tmux and rc pointers, coexistence with menu bar managers — under a strict no-exfiltration, no-telemetry stance.

## Evidence and open questions

**Relied on:** `README.md`; `CHANGELOG.md` (3.0.4–4.2.0); `docs/{menu-bar,multi-account-cli,data-and-privacy,codex-subscriptions}.md`; `SECURITY.md`; `CONTRIBUTING.md`; `RELEASING.md`; `project-documentation/implementation-plans/active-execution/claude-usage-desktop-app-codex-support/{implementation-plan,decisions,final-parity-audit}.md`; sources `Claude Usage/Shared/Services/{ClaudeAPIService,ClaudeCLITokenRefresher,ClaudeSwitchService,AutoStartSessionService,KeychainService}.swift`, `Claude Usage/MenuBar/{MenuBarManager,MenuBarManagerDetection}.swift`, `Packages/UsageKit/Sources/CodexUsageProvider/Transport/CodexProtocol.swift`, `Claude Usage/Resources/*.lproj`.

**Owner answers (2026-09-03)**
1. Accounts per user: two to about ten, no hard limit by design. Overflow and menu-bar-manager behaviour matter up to ten.
2. Assume mixed users biased toward Claude. Hunt Codex paths proportionally less, never skip them.
3. Auto-switch should move the CLI as well as the viewed profile. Verified in code: `checkAutoSwitchIfNeeded` calls `ProfileManager.activateProfile`, the same path as Make Active, which rewrites the CLI pointers (`CODEX_HOME` linked home, Claude account link) and tmux environment. The owner has not used the feature; treat it as promising but unproven, and weight bugs in it by JTBD 4.
4. No loud complaints today. Rank by the promise, not by inbound reports.
5. Login-Keychain-only: unknown. If the current stance is weak, improve it. The bug loop should assess whether another process could read the stored items without a user prompt, and the dream loop may propose returning to the data-protection Keychain with the migration cost spelled out.
6. Team/Enterprise org-versus-member correctness is first-class.
