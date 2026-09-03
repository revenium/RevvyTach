### ideas-3-02 · Rank the +N overflow list by headroom and show session and weekly side by side
**Job:** JTBD-1 "At the limiter, find headroom … all accounts' session + weekly % side by side." · **Lens:** ten-times (merged with job-gap)
**Score:** 4.00 = value 2 × confidence 4 ÷ (risk 2 × effort S=1)
- value: lowered from 3 — the surface is defined by exclusion, so this advances JTBD-1 only for the accounts that did not fit, never for "all accounts."
- confidence: every claim was opened and confirmed in source; the benefit itself is inferred from the promise, not from a user report — the owner states there are no inbound complaints.
- risk: pure presentation change to one static function; no network, no credential, no status item identity or saved position touched.
- effort: one builder, one SwiftUI row, two existing tests to extend, and one private function made internal; zero new localized strings.

**User story.** As a developer with 7–10 profiles where several are collapsed behind the "+N" item, when I open that list the moment I hit a limit, I want the hidden accounts ordered by remaining headroom with both windows per row, so that "at a glance" still means something once some accounts no longer fit on screen.

**Why we think it is valuable.** The overflow list is the only place several accounts appear together as text with numbers, and it shows one number each, in arbitrary order. `OverflowProfileRow` carries exactly `id`, `name`, `percentageText` (`Claude Usage/MenuBar/Components/OverflowProfileListView.swift:16-20`) and the view renders `ForEach(rows)` with no sort (`:41`). `MenuBarManager.overflowProfileRows` (`Claude Usage/MenuBar/MenuBarManager.swift:2432-2449`) maps `profileIDs` straight through and takes `presentation.metric?.percentageText ?? "—"`, where `metric` is `metrics.first` (`Claude Usage/Shared/Models/ProviderAppearance.swift:229`) — one window per row by construction. The second number costs no extra fetch: `claudeCatalog` builds Session and Week from the same snapshot in the same call (`ProviderAppearance.swift:806-857`), and both names are already localized in all 9 locales (`en.lproj/Localizable.strings:1261-1262`).

Two sharp edges the candidate did not name. `showRemainingPercentage` is per-profile (`ProviderAppearance.swift:656`, applied `:971-972`), so one row can read "used" and the next "remaining" with nothing distinguishing them — the sort must key off `descriptor.usedPercentage`, never rendered text. And which profiles land in overflow is `Array(profiles.dropFirst(individualLimit))` (`StatusBarUIManager.swift:47-58`) over `selectedProfiles` (`:1251-1257`), a positional tail unrelated to usage.

Correcting the candidate: the app does sort profiles (provider, then name); what is absent is any sort keyed on usage. `docs/menu-bar.md:112-117` confirms saved item position is load-bearing for managers, so sorting the list only is the right constraint.

**What it would take.** Effort S. Touch surface: `MenuBarManager.overflowProfileRows`, `OverflowProfileRow`/`OverflowProfileRowButton`, `ProviderMenuPresentationBuilder`, `Claude UsageTests/StatusBarOverflowTests.swift`. First slice (rescoped after the critic): render both windows per row using the already-localized "Session" and "Week" names, and sort by ascending used percentage with unmeasured last and ties by name — icon order untouched, zero new strings, so it clears `validate_localizations.sh` unchanged. Revvie could implement unattended: yes — pure static logic with tests at `StatusBarOverflowTests.swift:219` and `:239` to extend.

**Risk.** Blast radius small, contained to one popover. Two failure-mode-1 hazards: sorting a list that mixes used- and remaining-polarity rows ranks it backwards, and a ranked partial set can read as a global answer — mitigated by the header the view already renders, `menubar.overflow.header` = "More Profiles" (`en.lproj:1255`), which names the set by exclusion. Unavailable readings must sort last as "—", never 0%.

**Alternatives.** Do nothing — with ≤6 profiles, and `.automatic` overflow standing down under Ice/Thaw/Bartender (`StatusBarUIManager.swift:92-97`), many primary users never see this list. Cheaper: sort only. Bigger prize, and a separate brief: the popover's Accounts chips carry no usage at all — `AccountChipPresentation` is id, provider, name, `isViewing`, `isActive` (`NormalizedUsageView.swift:72-78`).

**Strongest objection (critic).** The idea sorts the wrong list, and the shipping slice delivers none of the value it is scored on. Overflow membership is `Array(profiles.dropFirst(individualLimit))` over `selectedProfiles` (`StatusBarUIManager.swift:1251-1257`, `:47-58`) — a positional tail unrelated to usage. Ranking that subset makes the top row read as "your freest account" when it is only "freest among those that did not fit": an answer that looks authoritative and is not, the promise's first-ranked failure. JTBD-1 asks for *all* accounts; the overflow popover is by construction defined by exclusion. Meanwhile the first slice is sort-only with no second window, while the brief's own Alternatives names the real gap — `AccountChipPresentation` (`NormalizedUsageView.swift:72-78`) shows every account, including to the manager users overflow excludes (`:92-97`). Value 3 → 2.

**Response.** Every cite holds: `:1251-1257` passes `selectedProfiles` to `overflowPlan`, and the tail is positional. I take value 3 → 2; score is now 4.00.

It does not kill the idea. The list already exists and already shows a number — today ordered by nothing, which is strictly worse than ordered within the hidden set. The "looks authoritative" risk is answered by the header the view already renders, "More Profiles" (`en.lproj:1255`), which names the set by exclusion at no localization cost.

The critic is right that sort-only ships no side-by-side, so the slice now includes both windows, reusing the existing localized "Session"/"Week" (`en.lproj:1261-1262`) — zero new keys. The cost: `metricPresentation` is `private static` (`ProviderAppearance.swift:963`) and must become internal rather than be reimplemented, which would be the second source of truth the file's own doc comment warns against.

The chips remain a separate, larger idea.

**Open questions for the owner.**
1. Should the sort key be raw used percentage even for profiles displaying "remaining," so one list has one meaning?
2. Is the overflow list worth this given it never appears under a menu bar manager — or should the effort go to the popover chips instead?
3. Does "Session 42% · Week 78%" fit the row in Japanese and German, given 4.0.8's clipping?
