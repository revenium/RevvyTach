### ideas-3-05 · Adopt existing ~/.claude-accounts sign-ins as profiles in one click
**Job:** JTBD-2 "Move the terminal with me" (setup side) · **Lens:** adjacent
**Score:** 0.44 = value 2 × confidence 2 ÷ (risk 3 × effort M=3)
- value: the population it would actually serve is the app's own deletion debris, so the button mostly offers to recreate a profile the user deliberately deleted.
- confidence: the code evidence is solid, but the cohort is not — `~/.claude-accounts/` is RevvyTach's own directory, so the "hand-rolled it earlier" user I wrote is near-fictional.
- risk: an unlabelled adopt row is failure mode 2 ("a profile absorbing another account's sign-in") offered as a button, and it also reveals that deletion never deleted.
- effort: M, not S — naming each row needs an authenticated request per directory, which the S-sized local slice cannot do.

**User story.** As a developer who hand-rolled several `CLAUDE_CONFIG_DIR` directories before finding RevvyTach, when I open the Claude Account page, I want the app to show me directories under `~/.claude-accounts/` that hold a usable Claude Code sign-in and belong to no profile, so that I can adopt each as a profile without guessing the exact name that makes linking reuse it.

**Why we think it is valuable.** The discovery primitive is written and wired to nothing: `availableAccountNames()` (`Claude Usage/Shared/Services/ClaudeSwitchService.swift:107-128`) is the only occurrence of that symbol in app or tests. Adoption already works too — `resolveDirectoryName` returns the name unchanged, commented "If it already has credentials, linkAccount will adopt it as-is" (`:727-731`), and `docs/multi-account-cli.md:51` confirms an existing directory is reused. What is missing is discovery: nothing lists what is there, so the user must name a profile whose slug matches exactly. The wizard refuses to help by design — "Do not guess among other linked accounts on a multi-account machine" (`Claude Usage/Views/SetupWizardView.swift:1605-1607`). That gap is real; the critic showed the users standing in it are not the ones I claimed.

**What it would take.** Effort M. Touch surface: `ClaudeSwitchService`, `ClaudeAccountView.swift`, `ProfileManager`, `ClaudeAPIService` (per-directory identity), 9 `.lproj` files. First slice (rescoped, and the reason it no longer pays): list unowned directories with a usable Keychain token, then resolve each one's organization over the network before showing a row, because a row that cannot say whose account it is must not exist. Revvie could implement unattended: no.

**Risk.** `performLinkAccount` sets `cliAccountName` from the sanitized profile name with no collision suffix and no ownership check (`ClaudeAccountView.swift:1488-1502`), so two profiles can already bind one directory. Adoption would widen that. Localization: ~4 strings × 9 locales.

**Alternatives.** Do nothing. Better: fix what the critic uncovered — deleting a profile should not leave a live Claude Code login on disk. That is a separate, stronger brief.

**Strongest objection (critic).** `~/.claude-accounts/` is not a convention developers hand-roll into — it is RevvyTach's own directory, created by this app (`ClaudeSwitchService.swift:12-14, 29-31`). Anyone who rolled their own `CLAUDE_CONFIG_DIR` setup used their own path, which this feature never sees, so the cohort is close to empty. What actually populates "a usable sign-in owned by no profile" is the app's own debris: `ProfileManager.deleteProfile` (`:926-1014`) scrubs secrets, history and usage but never calls `unlinkAccount`, so every deleted Claude profile leaves its directory and live login behind. On a seven-profile machine the list mostly says "recreate the profile you deliberately deleted" — with no identity shown, since the Keychain filter proves a token is usable, not whose. That is failure mode 2 offered as a button.

**Response.** DROPPED — objection wins. Every code claim holds. `~/.claude-accounts` is the app's own directory; no doc tells a user to create one, and "claude-switch" appears only in two internal comments, so I have no evidence of a pre-existing cohort. `deleteProfile` (`ProfileManager.swift:926-1013`) never calls `unlinkAccount` — `deletionCleanup` only clears notifications (`:80-85`) — so leftovers are real and are the actual population. Naming each row also costs more than assumed: the app extracts no email anywhere, and the identity it trusts is the organization, deliberately ("an email or account match proves nothing", `ClaudeAPIService.swift:1157-1161`), meaning one authenticated request per unowned directory. Serving the real cohort well is "deleting a profile should not leave a live login on disk" — a different, better brief the critic has effectively written.

**Open questions for the owner.**
1. Should deleting a Claude profile also unlink its account directory, or offer to?
2. Is a leftover directory holding a live Claude Code login a privacy issue worth its own fix?
