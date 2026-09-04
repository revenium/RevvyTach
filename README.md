# RevvyTach

[![Revenium Labs](https://img.shields.io/badge/Revenium-Labs-6f42c1?style=for-the-badge)](https://github.com/revenium/.github/blob/main/LABS.md)
[![Status: Beta](https://img.shields.io/badge/status-beta%20(best--effort)-f0a020?style=for-the-badge)](https://github.com/revenium/.github/blob/main/LABS.md)

> ### 🧪 This is a Revenium Labs project
> **Revenium Labs** projects are field-developed, best-effort solutions. They are working,
> beta-quality software, built to solve real customer problems and shared in the open. They are
> **not** part of Revenium's officially supported products.
>
> - It works and solves a real problem, but may need adaptation to fit your exact environment.
> - It's provided as-is, without the versioned-release guarantees, SLAs, or formal support
>   that back our core products.
> - We welcome your issues, feedback, and PRs, and **we're happy to work with you** to make it
>   fit your use case. [Come talk to us on Discord](https://discord.gg/J2DbmjZ2nA).
>
> → **[What is Revenium Labs?](https://github.com/revenium/.github/blob/main/LABS.md)**

<div align="center">
  <img src=".github/revvytach-icon.png" alt="RevvyTach — Revvy the raccoon at the hub of a rev-counter gauge" width="200">

  **A native macOS menu bar app for people running more than one Claude or Codex account**

  <sub>**Why "RevvyTach"?** A tachometer tells you how hard the engine is revving and how close
  you are to redline. That's what this app does for your AI coding subscriptions — it sits in
  the menu bar showing how hard you're running each account and warns you before you hit the
  limiter. Revvy is <a href="https://revenium.io">Revenium</a>'s raccoon mascot, who kindly
  lent his name to a gauge.</sub>

  [![Release](https://img.shields.io/github/v/release/revenium/RevvyTach?style=flat-square)](https://github.com/revenium/RevvyTach/releases/latest)
  [![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)](LICENSE)

  <sub>🇬🇧 English • 🇪🇸 Español • 🇫🇷 Français • 🇩🇪 Deutsch • 🇮🇹 Italiano • 🇵🇹 Português • 🇯🇵 日本語 • 🇰🇷 한국어 • 🇨🇳 简体中文</sub>

  ### [Download Latest Release](https://github.com/revenium/RevvyTach/releases/latest/download/RevvyTach.dmg)

  <sub>macOS 14.0+ (Sonoma) · Native Swift/SwiftUI · Signed and notarized</sub>
</div>

---

## Is this for you?

If you have one Claude account and just want to see your 5-hour window in the menu bar, this
works fine — but so would something simpler.

This is built for the case that gets painful: **several Claude accounts, or several ChatGPT
accounts used through Codex, or both at once.** The problems it solves are the ones you only
have at that scale:

- You hit a 5-hour or weekly limit and need to know **which of your accounts still has
  headroom**, right now, without opening six browser tabs.
- Once you know, you need your **terminal** on that account — `claude` and `codex` picking up
  the right credentials — without logging out and back in.
- You want **all of your accounts visible in the menu bar at once**, not one at a time.
- Your menu bar is already crowded and you run a manager like Ice, Thaw, or Bartender.

Claude and Codex are tracked side by side, with one active Claude account and one active Codex
account at the same time. Activating one never touches the other's credentials, environment,
or CLI state.

<div align="center">
  <img src=".github/settings.gif" alt="Quick Walkthrough" width="600">
  <img src=".github/icon.jpg" alt="Menu Bar Icon" height="180">
  <img src=".github/popover.png" alt="Popover Interface" width="200">
</div>

---

## Install

### Homebrew

```bash
brew install --cask revenium/tap/revvytach
```

Update with `brew upgrade --cask revvytach`, remove with `brew uninstall --cask revvytach`.

### Direct download

**[Download `RevvyTach.dmg`](https://github.com/revenium/RevvyTach/releases/latest/download/RevvyTach.dmg)**,
open it, drag the app to Applications, and launch it. Releases ship a single notarized disk
image — signed with an Apple Developer ID, so there are no Gatekeeper workarounds to perform.

The app updates itself (Settings → Updates) via Sparkle, over HTTPS with signature verification.

### Build from source

```bash
git clone https://github.com/revenium/RevvyTach.git
cd RevvyTach
open "Claude Usage.xcodeproj"   # then ⌘R
```

---

## Set up your first account

Every account you track is a **profile**. Profiles are per-provider: a profile is either a
Claude profile or a Codex profile, and you can have as many of each as you like.

### Claude

Pick whichever of these you already have:

| | How | Notes |
|---|---|---|
| **Claude Code** | Nothing to do — if the CLI is installed and logged in, the app finds it | Easiest |
| **Chrome-assisted key** | Settings → Claude.AI → choose a Chrome profile | Opens that profile at Claude for visual account verification; you paste and validate the key manually, or press the optional **Read from Chrome** button, which reads the one `claude.ai` session-key cookie after a macOS password prompt you approve. Opening a profile itself reads only Chrome profile labels/directories. |
| **Browser sign-in** | Settings → Claude.AI → **Sign in to Claude.ai** | Embedded-browser fallback; the session key is extracted and stored for you |
| **Manual key** | Session-key field in the same Chrome-assisted panel | Paste the `sessionKey` cookie from claude.ai, test, pick your org |

Optionally add Settings → API Console to track Anthropic Console spend, prepaid credits, and
per-key cost breakdown alongside subscription usage.

> Session keys expire. You get a notification 24 hours ahead; re-authenticate from the same
> screen.

### Codex

Codex tracking requires the official `codex` CLI installed and able to run `codex app-server`,
signed in with the ChatGPT subscription you want to watch.

1. Choose **Codex** in first-run setup, or add a Codex profile in Settings → Manage Profiles.
2. Point it at the existing `CODEX_HOME` directory that Codex installation uses, and verify it.
3. Use **Provider Account** to check health, sign in, relink, or unlink.

The app delegates authentication and usage reads to the official Codex app-server process. It
never reads, parses, or copies `auth.json` or any Codex token.

→ **[Codex subscription support](docs/codex-subscriptions.md)** — eligibility, what is and
isn't reported, relinking a moved home, troubleshooting.

---

## Working across accounts

This is the part the app exists for.

### Viewing vs. activating

Clicking any account shows you its usage. It does **not** switch to it. The popover lists every
profile grouped by provider — a green dot marks the active one, an accent marks the one you're
viewing — and switching is an explicit **Make Active** button.

The split is deliberate: checking whether another account has headroom is something you do
constantly, and it should never move your CLI out from under a running session.

### Switching your terminal with your profile

Activating a profile can carry your command line with it:

- **Claude Code** — each linked profile gets its own config directory under
  `~/.claude-accounts/`, selected via `CLAUDE_CONFIG_DIR`. Activating a profile points
  `~/.claude-tokens/.last-account` at it and propagates the change to running `tmux` sessions.
- **Codex** — activating a Codex profile writes `~/.claude-tokens/.last-codex-home` and
  propagates `CODEX_HOME` the same way.

New shells follow along via a small snippet in your shell rc. Settings shows you the snippet
and tells you whether you actually need it — with a single Claude Code account, or a single
Codex home at the default `~/.codex`, you don't.

The app never edits your shell configuration files.

### Keeping accounts consistent

Multiple config directories mean things you add to one account don't exist in the others. Two
syncs fix that, both from Settings → CLI Account:

- **MCP servers** — a bidirectional merge across `~/.claude.json` and every linked account, run
  automatically on profile switch (on by default) or manually. It only ever adds what's
  missing; it never overwrites an existing entry, and project-scoped MCP servers are untouched.
- **Skills** — links a source directory of skills into `~/.claude/skills/`, which every account
  directory already points at. Pick the source directory in the same screen; if you don't, it
  falls back to `~/dotfiles/.claude/skills` when that exists, and otherwise does nothing.

> **Trust model:** MCP sync is bidirectional, so a server configured in any linked account can
> propagate to all of them. If you need strict isolation between accounts, turn off auto-sync
> and sync manually.

→ **[Multi-account and CLI switching](docs/multi-account-cli.md)** — linking, unlinking, the
shell snippet, what's written where, and what to do when it goes wrong.

---

## The menu bar with many accounts

Show one account or all of them (Settings → Manage Profiles → display mode). Each gets its own
icon, its own style, and its own refresh interval, and clicking any of them opens that account's
usage.

Past a certain number, they stop fitting. Collapse modes:

| Mode | Behaviour |
|---|---|
| **Automatic** (default) | Collapses into a `+N` item only when the menu bar genuinely has no room, measured against the display the items are on |
| **Never** | Always show every account |
| **After N** | Collapse past a fixed count you choose |

**If you run a menu bar manager** — Ice, Thaw, Bartender, Hidden Bar, Dozer, or Vanilla —
automatic mode detects it and stands down, because your manager is already solving overflow and
collapsing on top of it would hide accounts behind an extra click. Settings tells you which
manager was detected so the change in behaviour reads as deliberate. Your menu bar arrangement
also survives app restarts and updates, so you don't re-place items after every release.

Several icon styles, a choice of color modes, optional provider glyphs and background tints to
tell Claude and Codex apart at a glance, and pace markers showing whether you're on track to
burn through the window.

→ **[Menu bar behaviour](docs/menu-bar.md)** — overflow modes in detail, manager interaction,
icon styles, and what to check when an item goes missing.

---

## What else it does

- **Usage history** — interactive charts of session, weekly, and billing data over time, with
  JSON and CSV export.
- **Notifications** — threshold alerts per profile, plus custom thresholds and a sound picker.
- **Automation** — start a new session automatically on reset; switch to the next available
  profile when one hits its limit.
- **Global shortcuts** — system-wide hotkeys that need no Accessibility permission.
- **Headless-friendly** — works on Macs driven over Remote Desktop.
- **Localized interface**, switchable live.

---

## What it does to your machine

Reasonable things to want to know before you install a menu bar app that holds your credentials.

**Credentials** live in the macOS Keychain. They are never written to disk in plaintext — if the
Keychain refuses a write, the credential is held in memory for the session, you're told, and
nothing is persisted. Anything left in cleartext by an older version is migrated out on upgrade.

**Files it writes:**

| Path | What |
|---|---|
| `~/Library/Application Support/RevvyTach/profile-data/<uuid>/` | Per-profile current usage and history JSON |
| `~/Library/Preferences/com.revenium.RevvyTach.plist` | Settings — no secrets |
| `~/.claude-accounts/<name>/` | Claude Code config directories, only for profiles you explicitly link |
| `~/.claude-tokens/.last-account`, `.last-codex-home` | Pointers your shell reads, only if you use CLI switching |

History is capped and pruned automatically. Upgrading from a version older than 3.3.6 triggers a
one-time repair on first write that archives and clears unreadable records left by an earlier
bug — you may see history files shrink substantially and an archive file appear beside them.

**Network it makes:** `claude.ai` and `console.anthropic.com` for usage, `status.claude.com` for
service status, GitHub for update checks. Codex usage isn't a call this app makes at all — it
comes from a local `codex app-server` process, using the authentication that home already holds.

**No telemetry, no analytics, no cloud sync.** Nothing about your usage is sent anywhere.

→ **[Data and privacy](docs/data-and-privacy.md)** — the full inventory of files, network calls,
and process boundaries.

---

## Settings reference

Credentials and profile settings apply to the selected profile. App settings are global.

| Section | What's in it |
|---|---|
| **Claude.AI** | Session key: browser sign-in, manual entry, organization selection |
| **API Console** | Anthropic Console key, org, spend, prepaid credits, key expiry status |
| **CLI Account** | Claude Code linking, MCP sync, skills sync, shell snippet |
| **Provider Account** | Codex home linking, verification, sign-in, health (Codex profiles) |
| **Appearance** | Icon style, color mode, pace marker, used/remaining, provider badges |
| **General** | Refresh interval, auto-start sessions, notification thresholds |
| **History** | Usage charts and JSON/CSV export |
| **Manage Profiles** | Create, rename, delete; display mode; overflow mode; auto-switch |
| **Popover** | Reset time display, time format |
| **App Settings** | Launch at login and other global behaviour |
| **Shortcuts** | Global hotkeys |
| **Language** | Interface language, applied live |
| **Updates** | Automatic checks, release notes, one-click install |
| **Debug** | Timed network capture with request/response detail |
| **Support**, **About** | Links, credits, version |

---

## Troubleshooting

<details>
<summary><b>Usage won't load / "Unauthorized" / 403</b></summary>

Your session key has probably expired. Settings → Claude.AI → **Sign in to Claude.ai** to
re-authenticate, or paste a fresh key under *Advanced: Manual Session Key*. If sign-in succeeds
but usage still fails, confirm the selected organization is the right one.
</details>

<details>
<summary><b>A Codex profile stopped working after I moved or reinstalled something</b></summary>

The link is to a specific physical directory, not a path. If the home was moved, replaced, or
restored as a different filesystem object, relink it: Settings → Provider Account → verify the
home. Symlink aliases and two profiles pointing at one home are rejected on purpose.
</details>

<details>
<summary><b>My accounts collapsed into "+N" and I have plenty of menu bar space</b></summary>

Set Settings → Manage Profiles → overflow mode to **Never**. If you run a menu bar manager,
automatic mode should already be standing down — check whether Settings names your manager. If
it doesn't, the manager isn't recognised; open an issue with its bundle identifier.
</details>

<details>
<summary><b>My menu bar manager can't move the app's items</b></summary>

Fixed in 3.3.3 and later. Update.
</details>

<details>
<summary><b>The account dropdown in the popover header is gone</b></summary>

Removed deliberately in 3.1.0. Every account is now listed in the popover's Accounts section —
click one to view it, and use **Make Active** to switch to it.
</details>

<details>
<summary><b>The Claude Code statusline integration disappeared</b></summary>

Removed in 3.2.0. Claude Code now supplies rate-limit data to statusline scripts natively —
`rate_limits.five_hour` and `rate_limits.seven_day` arrive on the script's stdin — so the app's
version solved a problem the platform solves itself. If you have an old
`~/.claude/fetch-claude-usage.swift` from a previous version, it's inert and safe to delete.
</details>

<details>
<summary><b>No menu bar icon at all</b></summary>

Check System Settings → Desktop & Dock → Menu Bar, restart the app, and look in Console.app for
errors. If you're on 3.3.0 specifically, that release could not launch at all — update.
</details>

---

## Contributing

Issues and pull requests are welcome. For anything substantial, open an issue first.

Before opening a PR, run the full gate — CI runs the same set:

```bash
swift test --package-path Packages/UsageKit
./scripts/validate_localizations.sh
./scripts/tests/test_validate_localizations.sh
./scripts/validate_distribution.sh

xcodebuild test -project "Claude Usage.xcodeproj" -scheme "Claude Usage" \
  -configuration Debug -destination "platform=macOS"

xcodebuild test -project "Claude Usage.xcodeproj" \
  -scheme "Claude Usage UI Tests" -configuration UITesting \
  -destination "platform=macOS,arch=arm64"
```

Any user-visible string must exist in every locale — `validate_localizations.sh` enforces it. The UI suite runs against a temporary store, a temporary `CODEX_HOME`, and a deterministic
fake Codex app-server; it needs no account and no network, but local runs do require UI
automation authorization. If Xcode stalls at `enabling automation mode`, enable Developer Mode
and grant Accessibility permission to the launching process in System Settings, then rerun.
Never script or bypass macOS TCC permissions.

Release process and signing are documented in [RELEASING.md](RELEASING.md). Conventions and
review expectations are in [CONTRIBUTING.md](CONTRIBUTING.md).

**Code style:** Swift API Design Guidelines, SwiftUI idioms, MVVM with protocol-oriented
services. Comment the non-obvious, not the obvious.

---

## About this fork

RevvyTach began as an independent open-source project called Claude Usage Tracker, which built
the menu bar app, the profile system, the setup wizard, code signing, automatic updates, and
the localization this version still rests on. Its copyright notice is preserved in
[LICENSE](LICENSE).

Revenium forked it at v3.0.3 to solve a problem the original didn't target: monitoring **many**
accounts across **two** providers, with the command line following along. Codex support,
per-provider active profiles, CLI account switching, and the menu bar work all come from this
fork. Once the app was tracking Codex as much as Claude, the old name both undersold it and
leaned on someone else's trademark, so the project was renamed RevvyTach. Full history is in
[CHANGELOG.md](CHANGELOG.md).

Thanks to everyone who contributed upstream, whose work is still in here:

<a href="https://github.com/novastate"><img src="https://github.com/novastate.png" width="40" height="40" alt="novastate" title="novastate"></a>
<a href="https://github.com/heathdutton"><img src="https://github.com/heathdutton.png" width="40" height="40" alt="heathdutton" title="heathdutton"></a>
<a href="https://github.com/tsvikas"><img src="https://github.com/tsvikas.png" width="40" height="40" alt="tsvikas" title="tsvikas"></a>
<a href="https://github.com/kynoptic"><img src="https://github.com/kynoptic.png" width="40" height="40" alt="kynoptic" title="kynoptic"></a>
<a href="https://github.com/bezlant"><img src="https://github.com/bezlant.png" width="40" height="40" alt="bezlant" title="bezlant"></a>
<a href="https://github.com/trickart"><img src="https://github.com/trickart.png" width="40" height="40" alt="trickart" title="trickart"></a>
<a href="https://github.com/Ali-Aldahmani"><img src="https://github.com/Ali-Aldahmani.png" width="40" height="40" alt="Ali-Aldahmani" title="Ali-Aldahmani"></a>
<a href="https://github.com/cuvitx"><img src="https://github.com/cuvitx.png" width="40" height="40" alt="cuvitx" title="cuvitx"></a>

---

## License

MIT — see [LICENSE](LICENSE).

## Disclaimer

Not affiliated with, endorsed by, or sponsored by Anthropic PBC or OpenAI. Claude is a trademark
of Anthropic PBC; Codex and ChatGPT are trademarks of OpenAI. This is an independent third-party
tool for monitoring your own usage.

<div align="center">
  <sub>Built by <a href="https://revenium.io">Revenium</a> · <a href="https://discord.gg/J2DbmjZ2nA">Discord</a></sub>
</div>
