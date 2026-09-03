### ideas-3-01 · Fix wrong-destination switching, then rank on real headroom

**Job:** JTBD-1 "At the limiter, find headroom" (also JTBD-4 "auto-switch to next profile with room") · **Lens:** ten-times (merged with job-gap ×2)
**Score:** 4.50 = value 3 × confidence 3 ÷ (risk 2 × effort 1)
- value: stops two verified ways the hotkey and auto-switch send you somewhere unusable, and makes the capacity test mean what JTBD-1 means (session *and* weekly); no longer claims best-account-in-one-keystroke.
- confidence: the defects are certain — exact lines below — but exposure depends on two surfaces the owner has never exercised, so the pain is inferred from code, not reports.
- risk: still changes where an existing hotkey and automation send you, on the same path that rewrites the CLI pointers, with no auto-switch tests today; no new UI strings, no new upstream field.
- effort: one pure helper plus two call sites, both inside `MenuBarManager`.

**User story.** As a developer running up to ten Claude/Codex accounts in tmux, when I hit a limit and press the switch hotkey (or auto-switch fires), I want to land only on an account I can actually use, so that the switch does not cost me a second interruption.

**Why we think it is valuable.** Verified in `Claude Usage/MenuBar/MenuBarManager.swift`:
- `switchToNextProfile()` (4400-4414) is `(currentIndex + 1) % count` — no usage, provider or credential filter at all, so the hotkey can land you on a Codex profile or one with dead credentials.
- `findNextAvailableProfile(after:)` (4205-4237), used only by `checkAutoSwitchIfNeeded` (4173), tests capacity solely as `effectiveSessionPercentage < 100.0` (4226-4228). That property flattens "no reading" to `0.0` (`Claude Usage/Shared/Models/ClaudeUsage.swift:21-40`), and line 4224 returns any profile with no stored usage at all — so an unmeasured account already reads as empty and gets picked.
- It never consults weekly: zero `weeklyPercentage` reads in the whole file (the weekly hits are reset-history bookkeeping). An account at 4% session and 100% weekly is offered as available.
- The hotkey is a real surface: `ShortcutAction.nextProfile` (`Claude Usage/Shared/Managers/ShortcutManager.swift:18`), bound in `Claude Usage/Views/Settings/App/ShortcutsSettingsView.swift:61-64`, strings at `Localizable.strings:923-924`. Being Carbon, it fires from inside a terminal.
- Speculation, flagged: that ranking by *time to limit* (`Claude Usage/Shared/Utilities/PaceStatus.swift:29-45` already projects this) beats ranking by raw %.

**What it would take.** Effort S. Touch surface: a pure helper in `Claude Usage/Shared/Utilities/`, two call sites in `MenuBarManager.swift`, tests alongside `Claude UsageTests/ProfileProviderCoreTests.swift`. First slice (rescoped — no ordering change): give the hotkey the same provider and `hasImmediatelyUsableCredentials` filter auto-switch has, and make the capacity test the *worse* of `readableSessionPercentage` and `readableWeeklyPercentage` (`ClaudeUsage.swift:38,53` — both already exist), with a profile that has no reading treated as ineligible rather than empty. Ranking by most headroom becomes a second slice, gated on the owner actually using these surfaces. Revvie could implement unattended: yes — the helper is pure and testable, but it must be *extracted* first (both functions are private in a 4,678-line `@MainActor` class with no auto-switch tests) and "unknown is ineligible" stated in the ticket.

**Risk.** Blast radius: the chosen profile goes through `activateProfile` (4192), the Make Active path that rewrites `CLAUDE_CONFIG_DIR` and tmux env — so a wrong destination is failure mode 2, not just a cosmetic miss. The rescoped slice only ever makes the test stricter, and "nobody eligible, stay put" is an already-handled branch (4174-4177). Security/privacy: none, no new data read. Localization: none while no strings are added.

**Alternatives.** Do nothing — the popover already shows session and weekly side by side, so JTBD-1 works, just not from the keyboard. Cheaper: fix only the hotkey's missing credential filter and leave the auto-switch capacity test alone.

**Strongest objection (critic).** The idea sells "most remaining headroom" but ranks on session % alone, and session is not headroom. JTBD-1 is session *plus* weekly: an account at 4% session and 100% weekly has no room. `MenuBarManager` never reads `weeklyPercentage`; the only capacity test is `effectiveSessionPercentage < 100.0` (4225-4229). Ranking would promote an unusable account, then via `activateProfile` — the Make Active path — silently repoint `CLAUDE_CONFIG_DIR` and tmux at it: failure mode 1 from our own arithmetic, dragging failure mode 2 along. The risk section guards only the unmeasured-equals-0% trap, not a measured profile ranked wrong. The 10x claim rests on two surfaces the owner has never exercised. VERDICT: SURVIVABLE — rescope to the defect fixes; rank on the worse of session/weekly.

**Response.** All three code claims hold: zero `weeklyPercentage` reads in `MenuBarManager.swift` (its weekly hits are reset-history bookkeeping), the capacity test is session-only at 4226-4228, and `activateProfile` is at 4192. Session-is-not-headroom is the point I missed and it is decisive for the ordering claim, so ranking moves to a second slice and the first slice becomes the verified defects plus an honest capacity test: worse-of(`readableSessionPercentage`, `readableWeeklyPercentage`), unknown ineligible — both accessors already exist. Value 4→3 (no longer claims best-account-in-one-keystroke), confidence 4→3 (defects certain in code; exposure depends on surfaces the owner has never used). Risk stays 2 rather than dropping: any change here still moves the CLI, and there are no auto-switch tests to catch a mistake.

**Open questions for the owner.**
1. Should the hotkey ever cross providers, or stay within the active profile's provider?
2. When no account is eligible on the worse-of test, stay put (today's behaviour) or fall back to the least-bad one?
3. Have you ever pressed the Next Profile hotkey? If not, the second slice should not be built.
