### ideas-3-07 · Close the last unguarded null-reads-as-zero path in model-scoped weekly limits

**Job:** JTBD-5 "Trust the numbers and trust the app with my keys" · **Lens:** failure-to-feature (rescoped after critique)
**Score:** 15.00 = value 3 × confidence 5 ÷ (risk 1 × effort S=1)
- value: removes a fabricated, available-looking 0% from the one model-usage path still unguarded against it — failure mode #1 — though the trigger is latent at this key rather than observed, which is why this is 3 and not higher.
- confidence: the defect is verified line by line, and the identical trap one function away was already fixed in 4.2.0 for exactly this reason; how likely upstream is to fire it is priced into value, not here.
- risk: one call swapped inside one function; callers already handle `nil`; no UI strings, no network, no credential path.
- effort: a single guard in `parseWeeklyScopedLimit`, inherited by both callers, plus tests in a file that already covers this class.

**User story.** As a developer with 2–10 accounts, when Anthropic reports a model's weekly figure as `null` or in a type RevvyTach does not model, I want that model's row to disappear rather than read 0%, so I never route work to an account on the strength of a number nobody sent.

**Why we think it is valuable.** `Claude Usage/Shared/Services/UsageLimitParsing.swift:104` guards with `guard let percent = limit["percent"] else { continue }`. `JSONSerialization` turns JSON `null` into `NSNull()`, which is non-nil, so the guard passes; line 106 then calls `parseUtilization`, whose `else` branch floors any unmodelled type to `0.0` (lines 117-135). A non-numeric string takes the same route via `Double(cleaned) ?? 0.0`.

That zero is not marked unavailable. `ClaudeAPIService.swift:3217` reads `opusUsage?.percentage ?? 0.0` and line 3247 sets `opusWeeklyLimitAvailable: opusUsage != nil` — true, because a tuple came back. `AutoStartSessionService.swift:296-327` repeats the shape identically, so the same fabricated zero also reaches the auto-start path.

The legacy top-level key beside it *is* guarded: `parseWeeklyModelUsage` (line 62) uses `parseUtilizationIfAvailable`, added in 4.2.0 precisely because Team accounts return `"seven_day_opus": null` (documented at lines 53-59). Same trap, same file, one path fixed and one not. Speculation, stated plainly: `null` has been observed at the legacy key, not yet at `limits[].percent` — this is a latent defect, not a reproduced one. The promise doc's constraint is unconditional regardless: "New fields must degrade to 'unavailable,' never zero."

**What it would take.** Effort S. Touch surface: `UsageLimitParsing.swift` (one function), `Claude UsageTests/UnknownUsageReadingTests.swift`. First slice: in `parseWeeklyScopedLimit`, replace `parseUtilization(percent)` with `parseUtilizationIfAvailable(percent)` and skip the entry when it yields nil, so the function returns nil and the row hides — the behaviour 4.2.0 established as correct. Both callers inherit it with no edit. Revvie could implement unattended: yes — one call site, 26 existing tests in `UnknownUsageReadingTests.swift` to extend, no UI or string changes.

**Risk.** Behaviour change is user-visible in one direction only: a row that showed 0% now hides. That is the shipped intent ("hide themselves when there is none, which is what the Fable row has always done", 4.2.0). A genuine `0` or `"0%"` still parses as an available measured zero. Decide whether an unparseable entry should `continue` to a later duplicate or return nil immediately; `continue` is safer. No localization cost, no new endpoint, no telemetry.

**Alternatives.** Do nothing — the path stays unguarded until upstream fires it, at the top-ranked failure mode's cost. The original, larger version of this brief (an `unrecognised(key, type)` outcome plus a diagnostics line) can ride along later; it is not needed to make the number honest.

**Strongest objection (critic).** The value is booked to the wrong beneficiary, and a one-line fix in the function you propose to refactor buys more of it. Your own value line concedes it "buys diagnosis speed, not a new correct number" — for whom? Not the primary user, who already gets the honest "—" (4.0.8/4.0.10). The consumer of `unrecognised(key, type)` is the maintainer, and the promise doc forecloses that channel twice: "No telemetry, analytics, crash reporting" and owner decision 4, "No loud complaints today." Meanwhile `UsageLimitParsing.swift:104-106` still manufactures failure mode #1: `NSNull` passes the guard, `parseUtilization` floors it to `0.0`, and `ClaudeAPIService.swift:3247` marks it available. Swapping one call is effort XS and turns a wrong number honest. **Verdict: rescope.**

**Response.** Accepted, and rescoped to exactly that fix. I verified every claim: the `NSNull`-passes-the-guard path holds at line 104-106, and the availability flag holds at 3247 (the caller's first line is 3217, not 3216 — immaterial). The unguarded path also feeds `AutoStartSessionService.swift:296-327`, which strengthens the point. One correction: the promise doc forbids *transmitting* data, not local diagnostics — `ProviderDiagnosticsService`'s user-copied `supportText` is an existing non-telemetry channel, so "no channel exists" overstates it. But owner decision 4 lands: with no inbound complaints, faster bug reports is weak value, and I should not have booked a maintainer benefit against a user job. Value 3→ kept but re-justified against correctness, effort M→S, risk 2→1.

**Open questions for the owner.**
1. Should an unparseable `limits` entry skip to a later duplicate for the same model, or return "no reading" immediately?
2. Worth extending the same guard to the Codex app-server response shapes now, or Claude only?
