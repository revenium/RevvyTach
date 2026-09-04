# Data and privacy

A complete account of what the app stores, where, what it sends over the network, and what it
deliberately never touches.

- [Credentials](#credentials)
- [Files on disk](#files-on-disk)
- [Usage history](#usage-history)
- [Network](#network)
- [The Codex process boundary](#the-codex-process-boundary)
- [What it never does](#what-it-never-does)

---

## Credentials

**Session keys and API keys live in the macOS Keychain.** They are never written to disk in
plaintext.

macOS offers two Keychains, and the app probes the Security framework at runtime to decide which
it can actually use: the data-protection Keychain when the process carries a Keychain access
group, and the login Keychain otherwise. **Shipped releases currently land on the login
Keychain.** The data-protection path requires an embedded provisioning profile the release
signing chain doesn't yet have; it was attempted in 3.3.0 and withdrawn in 3.3.1 when it turned
out to prevent the app launching at all. The resolver decides by probing rather than by reading
its own entitlements, so nothing is migrated, moved, or deleted while that remains true.

**The credential store fails closed.** If the Keychain refuses a write:

- the credential is held in memory and works for the rest of the session
- nothing is written to disk
- the app tells you the credential is memory-only rather than degrading silently
- if secure storage never accepts it, it's gone at quit and you re-authenticate

Versions before 3.2.0 could park a session key in cleartext in the app's preferences file when
the Keychain was unavailable. That field is no longer written under any circumstance, and any
value an older version left behind is migrated into the Keychain and cleared on first read.

**Claude Code credentials** are read from the CLI's own Keychain item and its
`.credentials.json`, and written back only when you link or switch a profile. Attribute lookups
use the Security framework directly; the credential read itself goes through `/usr/bin/security`,
because the item's access control trusts that binary rather than this app.

---

## Files on disk

| Path | Contents | Secrets? |
|---|---|---|
| `~/Library/Application Support/RevvyTach/profile-data/<profile-uuid>/current-v1.json` | Latest usage snapshot for that profile | No |
| `~/Library/Application Support/RevvyTach/profile-data/<profile-uuid>/history-v1.json` | Usage history for that profile | No |
| `~/Library/Preferences/com.revenium.RevvyTach.plist` | Every setting and preference | No |
| macOS Keychain | Session keys, API keys | Yes |
| `~/.claude-accounts/<name>/` | A Claude Code config directory, created only for profiles you explicitly link | Yes — the CLI's own |
| `~/.claude-tokens/.last-account` | Name of the active Claude account directory | No |
| `~/.claude-tokens/.last-codex-home` | Absolute path of the active Codex home | No |
| `$TMPDIR/revvytach-chrome-<uuid>/` | A transient copy of one Chrome profile's cookie database, made only while **Read from Chrome** runs and deleted immediately afterwards | Yes — Chrome's own encrypted cookies; only the claude.ai session key is ever decrypted |

On first launch after the RevvyTach rename, the app imports settings from the pre-rename
preferences domain (`HamedElfayome.Claude-Usage`) and copies the old `Claude Usage`
Application Support folder, so upgrading preserves everything. The legacy files are left in
place and can be deleted once you're satisfied with the upgrade.

Writes to the JSON stores are atomic — written to a temporary file, then renamed — with a `.bak`
alongside, because an interrupted write on a large history file is not hypothetical. Stale
fragments from interrupted writes are swept automatically, restricted to files this app owns.

Nothing outside these paths is written. The one transient exception is the temporary
cookie-database copy in the table above, which exists only while you run **Read from Chrome**
and is deleted as soon as the read finishes; a leftover from a crash is swept at the next
launch. The app does not edit your shell configuration, your `settings.json`, or any Codex
file.

### Chrome-assisted setup

When you choose the Chrome-assisted session-key path, RevvyTach reads Chrome's `Local State`
file for profile labels and directory names only, so it can offer a profile picker. Selecting a
profile opens that profile at Claude in Chrome so you can visually confirm the account. Opening
a profile reads nothing else — no cookies, no login database, no history, no account identifiers.

**Read from Chrome (optional, off until you press it).** On the session-key step, after you have
opened a specific Chrome profile, a **Read from Chrome** button becomes available. It is never
automatic: it does nothing until you press it and approve a macOS prompt, and it is scoped to
the one profile you just opened. When you press it and continue past the consent notice,
RevvyTach:

- makes a temporary private copy of that profile's cookie database in a per-run folder under
  your temporary directory, and looks for the `claude.ai` `sessionKey` cookie in it. Chrome keeps
  that database at `Cookies` (some builds at `Network/Cookies`); whichever exist are copied, each
  with its `-wal`/`-shm` sidecars. The copy contains **every** cookie in that profile, in Chrome's
  own encrypted form. Only the one session-key value is ever decrypted.
- if — and only if — that cookie is present and encrypted, asks macOS for the "Chrome Safe
  Storage" key from your login keychain using the system Keychain API. macOS shows its own
  password prompt, naming RevvyTach. **Approving it gives RevvyTach the key itself: the same
  key that unlocks every cookie and every saved password in Chrome. macOS does not narrow it
  to one cookie — only RevvyTach's own code does.** Click **Allow**, which is a one-time grant
  that macOS will ask for again the next time you read. Do **not** click **Always Allow**: that
  grant never expires and survives deleting RevvyTach. You can revoke it at any time in
  Keychain Access → login → "Chrome Safe Storage" → Access Control → remove RevvyTach.
- deletes the temporary copy immediately — on success and on every error path. If the app is
  killed mid-read, the next launch sweeps any leftover copy.
- fills the decrypted key into the same field you would otherwise paste into, then validates it
  the usual way. Nothing else from Chrome is read, and no other cookie or password is decrypted.

If there is no usable claude.ai session key in that profile, **no password prompt is shown at
all** — RevvyTach looks in the cookie copy first and only asks for the key once it knows there
is something to decrypt. The same is true for an older, unencrypted cookie.

If anything fails — you deny the prompt, the database is busy, the key isn't there or has
expired, or the encryption format is one this version doesn't recognize — RevvyTach tells you
plainly and asks you to paste the key manually. It never guesses.

**What is kept.** The session key is stored exactly as a manually pasted key is: in the
login Keychain once you finish setup, never in cleartext on disk. The "Chrome Safe Storage" key,
the temporary database copy, and every other cookie are never stored, never logged, and never
leave your machine. The decrypted session key is a normal in-memory string for as long as any
pasted key would be; RevvyTach does not claim to scrub it from memory, only that it is never
persisted in the clear and never written to logs or diagnostics.

---

## Usage history

History is recorded per profile and used for the charts and the JSON/CSV export. Each record type
is capped and pruned automatically, so history stays bounded without any attention from you —
roughly a week of session history and several weeks of weekly history are retained. The exact
caps live in `HistoryRetentionPolicy`.

### The one-time repair on upgrade

If you're upgrading from a version older than **3.3.6**, expect a one-time repair the first time
each profile writes history — roughly a second, once, per profile.

Earlier versions declared a "reset" whenever the provider's reset instant moved. Claude anchors
its session window to your first message, so that instant moves constantly without any reset
occurring, hundreds of times a day. Each false positive wrote a snapshot dated ahead of itself,
which every chart, view, and export then correctly filtered out — forever. On long-running
profiles those unreachable records reached roughly **97% of all stored history**, with files
growing past 20MB.

3.3.5 stopped new ones being written. 3.3.6 removes the ones already stored:

- Every removed record is **first copied to an archive file kept beside the history file**.
  Nothing is discarded outright.
- Only unreachable records are removed. Everything the app can display is preserved — the charts
  and exports are identical before and after.
- If archiving fails, nothing is removed and the repair simply retries on the next write.

You may notice history files shrinking substantially and an archive file appearing next to them.
That is the repair, and it runs once.

---

## Network

| Host | Why |
|---|---|
| `claude.ai` | Subscription usage for Claude profiles |
| `console.anthropic.com` | Anthropic Console usage, spend, and credits, if you configure it |
| `status.claude.com` | Claude service status shown in the popover |
| `github.com` | Update checks and downloads (Sparkle, over HTTPS with signature verification) |

All communication is HTTPS. Requests carry your credential to the provider that issued it and
nowhere else.

Refreshes are staggered across profiles rather than fired simultaneously, and back off
exponentially on rate limiting, honouring `Retry-After`. Polling pauses while the display is
asleep.

Settings → **Debug** offers a timed network capture with full request and response detail, if you
want to see exactly what's being sent.

---

## The Codex process boundary

Codex usage does not come from a network call this app makes. For each operation the app:

1. Resolves one absolute `codex` executable.
2. Starts a bounded `codex app-server` process against the linked `CODEX_HOME`.
3. Reads the response over that process's interface.
4. Terminates the process.

It never reads, parses, copies, uploads, or stores `CODEX_HOME/auth.json` or any Codex access
token. Authentication is entirely the Codex CLI's, using the state that home already holds.

See [Codex subscription support](codex-subscriptions.md) for what is and isn't reported.

---

## What it never does

- **No telemetry.** No analytics, no crash reporting, no usage statistics, no phone-home.
- **No cloud sync.** Everything stays on your machine.
- **No third-party services.** The only hosts contacted are the ones listed above.
- **No credential exfiltration.** Credentials go to the provider that issued them, over HTTPS,
  and nowhere else.
- **No silent browser access.** Chrome-assisted setup reads Chrome cookies only through the
  optional **Read from Chrome** button, only for the `claude.ai` session key, only after your
  explicit press and a macOS password prompt you approve, and only for the profile you opened.
  It never reads login databases or saved passwords, and never uses remote debugging,
  extensions, or browser automation. See "Chrome-assisted setup" above.
- **No account access beyond reading usage.** The app cannot send messages, spend credits, or
  redeem anything. Codex reset credits are display-only.

The app is open source under the MIT license — all of the above is verifiable in this
repository.
