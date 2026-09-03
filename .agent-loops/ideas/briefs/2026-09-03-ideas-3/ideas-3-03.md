### ideas-3-03 · Battery icon shows the reset countdown alongside the percentage, not instead of it

**Job:** JTBD-1 "At the limiter, find headroom." · **Lens:** parity (upstream Claude Usage Tracker issue #195, verified OPEN)
**Score:** 2.50 = value 1 × confidence 5 ÷ (risk 2 × effort S=1)
- value: very small — the Battery countdown exists only in single-profile metric mode, the user the promise excludes, and the bar fill already encodes the percentage (was 2; the critic's value argument holds, for a stronger reason than he gave).
- confidence: high — read both render paths line by line, fetched the upstream issue, found the existing render-test harness.
- risk: low — one drawing branch behind a default-off toggle, but no width/fit test exists in the repo, and a clipped `78% →2` would be a wrong number.
- effort: one `if` branch, a width measurement, and a case in an existing test.

**User story.** As a developer glancing at a Battery-style menu bar item to find headroom, when I turn on the reset countdown, I want the percentage kept beside it so a near-limit account resetting in ten minutes doesn't read the same as one resetting in four hours.

**Why we think it is valuable.** In `Claude Usage/MenuBar/MenuBarIconRenderer.swift`, the comment at line 900 says the label "replaces percentage text," and lines 908-927 confirm it: with the countdown on the label is `→2H` (or `S (→2H)`), and the percentage branch at 922-927 is only reached when the countdown is off. Upstream issue #195 (fetched 2026-09-03, still open) asks for exactly this, in exactly the Battery view. `Claude UsageTests/UnknownUsageReadingTests.swift:637` states the same constraint in a test comment.

Two corrections to the original candidate: **Progress Bar style is not the same case** (lines 1051-1072 draw the countdown inside the fill; that style has no percentage text to replace), and the loss only bites when icon names are off.

A quieter upside: today an unread session with the countdown on shows only `→2H` over a dashed bar. Appending `displayText` surfaces the honest "—" glyph (lines 712-715), serving the top-ranked failure mode.

**What it would take.** Effort S. Touch surface: the battery branch of `MenuBarIconRenderer.swift` (900-927) and `Claude UsageTests/UnknownUsageReadingTests.swift`. First slice (rescoped per the critic): compose `displayText · timeRemainingHoursString()`, **measure it, and fall back to percentage-only when it does not fit the existing 42pt** — never widen, never clip. No new localized keys: both fragments are generated, non-localized text. Revvie could implement unattended: yes — `UnknownUsageReadingTests.swift:605-690` already renders icons and fingerprints them.

**Risk.** Blast radius is one style in one mode, default-off. Clipping is the only real hazard and the fit rule removes it by construction, but the assertion is new test code, not an existing gate. No upstream API, credential, or privacy surface touched.

**Alternatives.** Do nothing — the popover pairs both figures (`UsageLimitGroupView.swift:252-295`) and the bar encodes the percentage. Cheaper: reword the settings description to say the countdown replaces the number.

**Strongest objection (critic).** Menu bar width here is not a cosmetic budget but the mechanism of the top job: `MenuBarSpaceCalculator` decides overflow by summing `ourItemWidths` against the measured free gap. Every point added per item is subtracted from how many profiles stay visible; at ten profiles, 42pt each is already ~420pt, so adding a percentage pushes items into `+N` — the promise's own symptom of a broken menu bar ("Accounts hidden"), against JTBD-7. It buys back a number the fill already encodes by spending the resource JTBD-1 depends on. Clipping is worse: a truncated `78% →2` is a wrong number on the most intolerable surface. Also `metric.countdown_description` is a settings sentence, not a composable label. Survivable only if the label must fit 42pt at measured width. Value 2 → 1.

**Response.** The central claim does not hold. Per-profile items — the ones in `ourItemWidths` (`StatusBarUIManager.swift:1214-1226`) — are rendered by `intendedItemWidth` → `renderProfileMenuBar` (1330-1345, 1618-1700), which switches over `MultiProfileIconStyle` (concentric/progressBar/compact/percentage) at ~34.5pt. **Battery is not in that set**, and `showNextSessionTime` exists only on `MetricIconConfig`, the legacy single-profile path (2160-2186). The two modes are mutually exclusive (`cleanup()` at 928 vs `setupMultiProfile` at 945), and overflow does not run outside multi-profile mode. So no profile is ever hidden by this. The critic is right about the fit rule and about `metric.countdown_description` (my "reusing the string" wording was wrong — the composed label needs no key because both fragments are generated). Adopted both; value cut to 1 because this surface belongs to the excluded single-account user.

**Open questions for the owner.**
1. Is single-profile Battery mode worth spending on at all, given the promise excludes that user?
2. If yes: `78%·2H` (no arrow) to fit 42pt, or keep the arrow and fall back more often?
