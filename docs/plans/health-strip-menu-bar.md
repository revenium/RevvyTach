# Health strip menu bar mode — implementation plan

Branch: `feat/health-strip-menu-bar` (base `origin/main` 3166e411). Opt-in; nothing changes for
existing users. Revised against `health-strip-menu-bar.redteam-1.md`.

## 1. Architecture decision

**Health strip is a *layout* chosen inside multi mode, not a third `ProfileDisplayMode` case and
not a `MultiProfileIconStyle`.** New type `MenuBarMultiLayout: String, Codable { perProfileItems,
healthStrip }`, persisted beside the overflow mode.

- **Not a `MultiProfileIconStyle`** (`MenuBarIconConfig.swift:519`). That enum picks how *one
  profile's own item* is drawn, and every consumer (`renderProfileMenuBar`
  `StatusBarUIManager.swift:1530`, `intendedItemWidth` `:1330`, `button(for:)` `:2093`, overflow
  planning `:1174`) assumes one item per profile. It would also sit in the icon-style picker as a
  peer of "Percentage", which it is not.
- **Not a third `ProfileDisplayMode` case.** `displayMode == .multi` appears **27 times** across
  `Claude Usage` (23 in `MenuBarManager.swift`), against only **two** exhaustive `switch`es over
  the enum (`MenuBarManager.swift:2922`, `NormalizedUsageView.swift:51`; the third switch at
  `UITestApplicationBootstrap.swift:706` is over a private local `ReconciliationMode`, `:500`). A
  new case makes all 27 comparisons silently false for strip users — refresh fan-out, popover
  targeting, credential-change routing and freshness deadlines stop, with no compiler error.
- **Layout enum inside multi mode** leaves `getSelectedProfiles` (`ProfileManager.swift:1079`),
  `capturedActionProfiles` (`MenuBarManager.swift:2917`), refresh and popover routing untouched,
  branching only where status items are built. The pattern `MenuBarOverflowMode` used.

Per-profile selection, Codex, refresh, notifications and the popover are unchanged. **Overflow is
bypassed in strip layout** — `currentOverflowPlan` is not consulted, the overflow item is hidden,
the Settings overflow block is disabled — which also avoids `MenuBarSpaceProbe`'s Accessibility
reads, relevant because a running menu bar manager already defeats automatic mode.

## 2. New types

```swift
// Shared/Models/MenuBarMultiLayout.swift
enum MenuBarMultiLayout: String, Codable { case perProfileItems, healthStrip }

// Shared/Models/MenuBarHealthStripNumbers.swift
enum MenuBarHealthStripNumbersThreshold: Equatable {
    case never
    case percent(Int)                              // 80 / 90 / 95
    static let defaultPercent = 90
    static let hysteresisPoints = 3
    enum StorageKind: String { case never, percent }
    var storageKind: StorageKind
}

enum HealthStripNumbers {                          // pure, no AppKit
    static func showsNumbers(
        sessionUsed: Double?, weekUsed: Double?,   // used %, never displayed %
        threshold: MenuBarHealthStripNumbersThreshold,
        isCurrentlyShowing: Bool
    ) -> Bool
}

// MenuBar/HealthStripLayout.swift — pure geometry
struct HealthStripCell: Equatable { let profileID: UUID; let minX: CGFloat; let width: CGFloat
                                    let numbersWidth: CGFloat? }
enum HealthStripLayout {
    static let barWidth: CGFloat = 4, cellGap: CGFloat = 3        // 7pt pitch at 1x
    static let barBottom: CGFloat = 4, barHeight: CGFloat = 12
    static let baseCanvasHeight: CGFloat = 22, edgePadding: CGFloat = 1
    static let numbersGap: CGFloat = 2, markerY: CGFloat = 17
    static func cells(for inputs: [(id: UUID, numbersWidth: CGFloat?)]) -> [HealthStripCell]
    static func totalWidth(_ cells: [HealthStripCell]) -> CGFloat
    static func profileID(atX x: CGFloat, in cells: [HealthStripCell]) -> UUID?
}
```

Persistence mirrors `DataStore.saveMenuBarOverflowMode` / `loadMenuBarOverflowMode`
(`DataStore.swift:154-213`): keys `menuBarMultiLayout`, `menuBarHealthStripNumbersKind`,
`menuBarHealthStripNumbersPercent` in `Constants.UserDefaultsKeys` beside `menuBarOverflowMode`
(`Constants.swift:81-83`). **Absent keys mean `.perProfileItems` and `.percent(90)`.** No
migration code.

## 3. Render math (1x points)

**One data source.** `updateHealthStrip` resolves each profile's usage **once**, snapshot-first —
`snapshot?.claudeUsage ?? profile.claudeUsage`, matching `claudeCatalog`
(`ProviderAppearance.swift:870`), the overflow list and `attention(for:)`
(`MenuBarManager.swift:3077`) — and feeds it to **both** the fill and the threshold. Not
`renderProfileMenuBar`'s `profile.claudeUsage ?? .empty` (`StatusBarUIManager.swift:1550`): a bar
and the number beside it would then disagree whenever a snapshot leads the profile record.

Per profile, in profile-list order:

- Track: rounded rect `x = cell.minX, y = 4, w = 4, h = 12`, menu bar foreground @ 0.18.
- Fill: same rect clipped to `h = 12 * displayFraction`, from the bottom, where
  `displayFraction = UsageStatusCalculator.getDisplayPercentage(usedPercentage:showRemaining:)/100`
  with `showRemaining = config.showRemainingPercentage` — so remaining mode reads "full bar = lots
  left", as `renderProfileMenuBar` does at `:1565`.
- Colour: `UsageStatusCalculator.calculateStatus(usedPercentage:showRemaining:elapsedFraction:)`
  (elapsed passed only when `config.usePaceColoring`) → `getColor(for:monochromeMode:
  useSystemColor:isDarkMode:)` (`:2455`). No new colour vocabulary.
- Unknown session (`!usage.sessionPercentageAvailable`): no fill; a 4 × 1.5 rounded dash at the
  track's middle, foreground @ 0.55 — `drawUnknownDash` (`MenuBarIconRenderer.swift:794`) narrowed
  from 8pt to the bar width. New `drawUnknownStripDash`; do not reuse the 8pt one.
- Active profile: 4 × 2 `systemGreen` rounded base at `y = 1` under its bar — the strip's form of
  `addGreenUnderline` (`StatusBarUIManager.swift:1484`), which underlines a whole image.
- Attention: new `drawStripAttentionMarker(atX:y:credential:isDarkMode:)` sharing the *shapes* of
  `applyAttentionMarker` (`:2239`) — filled red disc for `.claudeCode`/`.setupIncomplete`,
  `.clear`-punched hollow amber ring for `.claudeAI`. **The two must not collapse into one shape.**
  Footprint is **5.5pt** (4pt marker plus the ±0.75 halo), centred on the 4pt bar inside the 7pt
  pitch, so 0.75pt clearance per side. `markerY = 17` puts the halo's top at 21.75, inside the 22pt
  canvas, and its bottom at 16.25, clear of the bar top at 16. The 1x "ring reads as a lighter dot"
  tradeoff is already documented at `:2239`; the tooltip and label name the credential regardless.
- Numbers (§4): `createMultiProfilePercentage(...)` is called unchanged and composited at
  `x = cell.minX + 6`, **vertically centred on the bar's span (y = 4…16)**, not bottom-aligned. Its
  height is `textSize.height + 11` with the profile label on and `textSize.height` alone with it
  off (`:2064-2069`), so canvas height is `max(22, ceil(numbersImage.height))` and the image is
  clamped inside it. Reusing the renderer keeps the digits, the " · ", the critical underline, the
  pace dot and the 3-char name identical to today's `.percentage` style.

Widths: `cell.width = 4 + 3` normally, `4 + 2 + numbersWidth + 3` with numbers. Eight plain
accounts = `1 + 8*7 + 1 = 58pt`, against roughly 470pt today.

`createHealthStrip` returns `HealthStripRender { image, cells, tooltip, accessibilityLabel }` so
the picture and the words cannot drift, the contract `ProfileMenuBarRender` (`:1501`) already sets.

## 4. Numbers threshold

**Default `.percent(90)`; picker `80 / 90 / 95 / Never`.** 80 fires for several of eight accounts
most days and gives the width straight back; 95 is too late to switch accounts; 90 is where the
remaining time starts to matter. The picker exists because the right level depends on account count.

Trigger on the **used** percentage of the **session window or the weekly window** — named
explicitly, never "the leading two windows", so an API-console profile cannot smuggle Claude's
Credits window in. Never the displayed figure (`tightestUsed`'s rule,
`MenuBarManager.swift:2448`). Unknown windows never trigger. Comparison is `>=`.

**Hysteresis:** once shown, numbers stay until the account drops 3 points below the threshold —
without it an account hovering at 90 widens and narrows the strip on every refresh, shifting every
neighbouring app's item. State is `private var healthStripNumbersShown: [UUID: Bool]` on
`StatusBarUIManager`: **never persisted**, pruned by the reconciliation that removes a profile's
status item (`reconcileMultiProfileItems`, `:1043`), cleared wholesale when the threshold setting
changes. Not on the SwiftUI view (resets every render), not keyed by index (transfers between
accounts on reorder).

**Placement: inline in the strip, beside that profile's own bar.** Giving a hot profile its own
`NSStatusItem` would create and destroy items as thresholds cross, discarding AppKit's saved
position and minting new window IDs each crossing (`:872`, `:1354`) — the churn the codebase warns
against, on a trigger driven by live data.

## 5. Accounts list (left click)

**SwiftUI popover, not `NSMenu`.** Rows carry a name, two windows, a pace dot, an attention flag,
an active marker and three actions; in `NSMenu` that means custom views, which lose keyboard and
VoiceOver behaviour and cannot do the two-line name-over-numbers layout 8 of 9 locales need
(`OverflowProfileListView.swift:133`).

**Row set:** `isSelectedForDisplay && !deletionInProgress && providerID == .claude` — the predicate
the strip draws (`StatusBarUIManager.swift:948`, `:1061`), not `updateAllStatusBarIcons`'s looser
`isSelectedForDisplay` alone (`MenuBarManager.swift:2994`).

**Sizing — the crash was content-derived Auto Layout, not `sizePopover`.**
`createContentViewController` (`MenuBarManager.swift:2131-2152`) records it: `sizingOptions =
.preferredContentSize` builds constraints from the content's ideal size, so a content change
re-invalidates layout inside AppKit's constraint-update pass. `sizePopover` (`:2161`), which
assigns `popover.contentSize` outright, is the *safe* path. Use the main popover's shape:

- `hostingController.sizingOptions = []`.
- `popover.contentSize = NSSize(width: PopoverDesign.width, height: h)`, `h` derived from the row
  count and capped; rows past the cap scroll inside a `ScrollView`.
- `behavior = .transient`, `animates = false`, own `NSPopover`, `closePopoverOrWindow()` first —
  the second-popover shape of `toggleOverflowPopover` (`:2539`).
- **Rows are a value snapshot taken at open**, and **any row action closes the popover first**, so
  content never mutates while shown.

**Row layout.** The container is *not* a `Button` — the name/numbers column is the "Open"
affordance, and three `Button`s nested inside an outer `Button` breaks hit testing. Name over
`Session 83% · Week 86%` on two lines (dash for no reading, via `OverflowProfileRow.valueText`),
pace dot, attention glyph matching the strip's shape, `Active` badge. To the right, **three small
SF Symbol icon buttons, always present in the view and the accessibility tree** — Make Active
(hidden only when `presentation.actions` has no `.activate`), Refresh, Open. Hover changes their
opacity only; each carries a localized `accessibilityLabel` and `toolTip`. Footer: **Refresh All**,
**Manage Profiles…**, **Quit**.

**Routing.** Make Active, Refresh, Open, Manage Profiles and Quit go through
`capturedTargetRouter()` (`MenuBarManager.swift:2864`) with a `ProviderStatusItemIdentity` per row,
keeping their staleness checks. **Refresh All is the one action that does not**:
`ProviderCapturedTargetActionRouter.Action` (`ProviderAppearance.swift:306`) has no fan-out case
and its refresh sink dispatches one profile. Add a `MenuBarManager` method that sets
`lastRefreshTriggerTime = Date()` (as the sink does at `:2885`) and calls
`refreshAllSelectedProfiles(trigger: .manual)` (`:4047`). `.manual` bypasses the per-profile
interval gate by design (`PerProfileAutoRefreshPolicy.shouldRefreshProfile`, `:251`) and writes no
`lastAutomaticRefreshByProfile` record. It refreshes every selected profile, Codex included.

Open reuses `selectOverflowProfile(_:)` (`:2580`), generalized to
`openProfilePopover(_ profileID: UUID, anchoredTo button: NSStatusBarButton)`; it writes
`clickedProfileId` via `toggleValidatedPopover` (`:2346`) and needs none of `setViewedProfile`'s
hydration (`:1037`), since every strip row is already selected for display.

**Right click** cannot stay on the unchanged path: `showContextMenu(for:)` (`:2751`) resolves one
identity per button (`statusIdentity(for:)`, `StatusBarUIManager.swift:793`) and the strip is one
button for N accounts, so every cell would target the active profile. Give it
`identityOverride: ProviderStatusItemIdentity?`; the strip branch in `togglePopover` (`:2282`)
resolves the cell via `healthStripProfileID(at:)`, reads the event through a guarded
`if let event = NSApp.currentEvent`, and falls back to the active profile on a padding hit.

## 6. Files and functions to touch

| File | Change |
|---|---|
| `Shared/Models/MenuBarMultiLayout.swift`, `MenuBarHealthStripNumbers.swift` | new |
| `Shared/Utilities/Constants.swift:81-83` | three keys beside the overflow keys |
| `Shared/Storage/DataStore.swift:154-213` | `save/loadMenuBarMultiLayout`, `save/loadHealthStripNumbersThreshold`, same shape |
| `MenuBar/HealthStripLayout.swift` | new, pure |
| `MenuBar/MenuBarIconRenderer.swift` | add `createHealthStrip`, `drawUnknownStripDash`, `drawStripAttentionMarker`; reuse `createMultiProfilePercentage` `:1979` and `getColor` `:2455` unchanged |
| `MenuBar/StatusBarUIManager.swift` | `multiLayout`; `healthStripStatusItem` (autosave `claude-usage-tracker.healthstrip`); `healthStripNumbersShown`; `setupMultiProfile` `:941` and `updateMultiProfileConfiguration` `:1055` partition by provider and layout; `currentOverflowPlan` `:1174` skipped; `updateOverflowItem` `:1354` hides; split the non-Claude half of `updateProviderMultiProfileButtons` `:1909` into `updateNonClaudeMultiProfileButtons`; new `updateHealthStrip`, `isHealthStripButton`, `healthStripProfileID(at:)`; **`hasValidStatusBar` `:2069`**, **`autosaveName(for sender:)` `:800`** and **`profileId(for sender:)` `:2102`** must all recognise the strip button; `reconcileMultiProfileItems` `:1043` prunes hysteresis; `cleanup` `:872` releases the strip under the same terminating rule |
| `MenuBar/MenuBarManager.swift` | `updateAllStatusBarIcons` `:2988` branches on layout; `setupMultiProfileMode` `:4003` / `updateMultiProfileDisplay` `:4030` read the layout from `DataStore` (safe there — `:4008` already reads the overflow mode); `togglePopover` `:2282` routes the strip; **`showContextMenu` `:2751` gains `identityOverride`**; new `toggleHealthStripPopover`, `openProfilePopover`, `refreshAllSelectedProfilesFromUI`; **all four overflow-recompute entry points gain the same per-profile-items guard: `handleScreenChange` `:3962`, `scheduleOverflowRecompute` `:3988`, `handleFrontmostAppChange` `:3834`, `handleMenuBarManagerActivityChange` `:3937`** |
| `MenuBar/Components/HealthStripAccountsView.swift` | new |
| `Views/Settings/App/ManageProfilesView.swift` | §7 |
| `Resources/*.lproj/Localizable.strings` (9) | §8 |
| `docs/menu-bar.md`, `CHANGELOG.md` | §10 |

**`hasValidStatusBar` is load-bearing.** It scans `statusItems`, `multiProfileStatusItems` and
`overflowStatusItem` only (`:2069`). `AppDelegate.swift:254` reruns `setup()` three seconds after
launch when it reads `false`, and `MenuBarManager.swift:3969` does the same on every screen-
parameter change; `setup()` reaches `cleanup()` (`:872`), which calls `removeStatusItem` and
discards every saved position. It must return `true` when `healthStripStatusItem?.button != nil`.

**Cold launch in strip layout still creates the per-profile Claude items**, hidden
(`isVisible = false`), so switching layouts back restores saved positions instead of minting fresh
items; `itemWidth(for:)` (`:1273`) already credits a hidden item zero width. **Codex keeps its own
visible items**, painted by `updateNonClaudeMultiProfileButtons`.

Data flow: refresh → `updateAllStatusBarIcons()` → layout branch → `updateHealthStrip(profiles:
config:threshold:activeClaudeProfileID:attention:snapshots:now:)` → `createHealthStrip` →
`setButtonImage` (the fingerprint cache at `:2394` suppresses no-op redraws), tooltip and label.

## 7. Settings

Settings → Manage Profiles, inside the multi-profile card (`ManageProfilesView.swift:100-400`):

1. The enable toggle (`:106`) is unchanged; the layout lives outside `ProfileDisplayMode`, so its
   `displayMode == .multi` getter still holds.
2. **Inside** the `if profileManager.displayMode == .multi` branch (`:120`), first after the
   profile-selection list, a segmented **Menu bar layout** picker — *One item per account* /
   *Health strip* — built like the icon-style picker at `:163`, writing through
   `DataStore.saveMenuBarMultiLayout` and enqueueing `.multiProfileConfigChanged` (`:521`).
   Accepted cost: `observeMultiProfileConfigChanges` (`:3736`) ends in
   `refreshUsage(trigger: .displayChanged)` (`:3752`), so a layout flip costs one fan-out refresh.
   Fine for a rarely-touched setting; do not add a second notification for it.
3. **Show numbers for accounts above** — a menu picker `80/90/95/Never` built like the overflow
   `afterCount` picker at `:350`, `.disabled(layout != .healthStrip)`, with a one-line hint.
4. The overflow block (`:295`) becomes `.disabled(layout == .healthStrip)`, its two hints hidden:
   the strip cannot overflow.
5. The icon-style picker (`:163`) becomes `.disabled(layout == .healthStrip)` with a hint saying it
   now applies to Codex items only. In strip layout `config.iconStyle` affects no Claude item, and
   a silently dead control is worse than a disabled one.

## 8. Localization — 12 new keys (English), all 9 locales

```
"multiprofile.layout.title"                  = "Menu bar layout";
"multiprofile.layout.per_profile"            = "One item per account";
"multiprofile.layout.health_strip"           = "Health strip";
"multiprofile.layout.description"            = "Health strip draws one small bar per account in a single menu bar item.";
"multiprofile.layout.icon_style_hint"        = "Icon style applies to Codex accounts while Health strip is on.";
"multiprofile.healthstrip.numbers_title"     = "Show numbers for accounts above";
"multiprofile.healthstrip.numbers_never"     = "Never";
"multiprofile.healthstrip.numbers_suffix"    = "% used";
"multiprofile.healthstrip.numbers_hint"      = "An account at or above this level also shows its numbers in the menu bar.";
"menubar.healthstrip.accessibility_label"    = "%@ Claude accounts";
"menubar.healthstrip.header"                 = "Claude Accounts";
"menubar.healthstrip.footer.refresh_all"     = "Refresh All";
"menubar.healthstrip.row.active_badge"       = "Active";
```

Reuse, do not duplicate: **`menu.provider.open_profile`** ("Open %@", `en.lproj:1259`, used at
`ProviderAppearance.swift:671`) for the Open button's label and tooltip, plus
`menu.provider.make_active`, `menu.provider.manage_profiles`, `common.refresh`, `common.quit`,
`menubar.accessibility.state.*`, `popover.normalized.value.used|remaining`. Edit
`Claude Usage/Resources/<lang>.lproj/Localizable.strings` — the built catalog is UTF-16, the
sources are not. Run `scripts/validate_localizations.sh`.

## 9. Tests

Target `Claude UsageTests`. Pure logic stays GUI-free as `MenuBarSpaceCalculatorTests` does; only
the lifecycle suite needs `HostedAppTestCase` (`HostedTestSupport.swift:29`).

1. **`HealthStripLayoutTests`** — pitch and total width for 1/8/20 profiles; numeric cells widen
   only their own cell; `profileID(atX:)` at both cell edges and `nil` in padding; order preserved.
2. **`HealthStripNumbersTests`** — session-only over, week-only over, both under, exactly at
   threshold, unknown windows and `.never` never trigger, remaining mode does not flip the trigger,
   hysteresis holds until 3 points below then releases, **and the map is pruned by
   `reconcileMultiProfileItems` and cleared when the threshold setting changes**.
3. **`HealthStripRenderTests`** — fill height tracks the display percentage; remaining mode inverts
   it; unknown session draws the dash and no fill; **the numbers image lies fully inside the canvas
   in both `showProfileLabel` states**, canvas height `max(22, ceil(image.height))`; the two
   credentials produce different images (`imageFingerprint`, `:2407`); active base only for the
   active profile; bar and numbers use the same resolved usage when snapshot and profile disagree.
4. **`HealthStripAccessibilityTests`** — tooltip names every listed profile; the label states each
   session value or the localized no-data wording; the credential sentence comes from
   `attentionStateText` and differs per credential; every row action button has a localized label.
5. **`HealthStripSettingsPersistenceTests`** — round-trip both settings; absent keys default to
   per-profile layout and 90; a stored 0 or unknown kind falls back to 90.
6. **`HealthStripStatusItemTests`** (hosted) — **`hasValidStatusBar` is `true` with the strip item
   alone**; a cold launch in strip layout creates hidden Claude items; entering and leaving the
   layout preserves every item identity (`multiProfileItemIdentityForTesting`, `:837`); Codex items
   stay visible; the strip item is created once, its `autosaveName` is exactly
   `claude-usage-tracker.healthstrip`, and `autosaveName(for:)` / `profileId(for:)` resolve it; the
   overflow item is hidden and `spaceProbe` is never consulted
   (`FakeSpaceProbe.makeLayoutInputCallCount`, `StatusBarOverflowTests.swift:40`).
7. **`HealthStripAccountRowTests`** — the row-set predicate excludes `deletionInProgress` and
   non-Claude profiles; order; dash for no reading; active and attention flags; `canActivate`
   follows `presentation.actions`.
8. **`HealthStripLocalizationFitTests`** — budget is
   `PopoverDesign.width - 2 * PopoverDesign.outerInset - 2 * 8` (**272pt**, already used at
   `PopoverHeaderLocalizationFitTests.swift:92` and stated at `OverflowProfileListView.swift:135`)
   **minus the measured width of the three action buttons and their spacing**. Assert the name and
   numbers columns fit what is left, in all 9 locales, at the real fonts. Never count characters.

## 10. Docs

`docs/menu-bar.md`: new "Health strip" section after "Display modes" (the table at `:19` gains a
row) — what the bars mean, the numbers threshold, what a click opens, and that Codex accounts keep
their own items. Extend "When accounts don't fit" (`:60`): overflow does not apply in strip layout.
`CHANGELOG.md` under `## [Unreleased] / ### Added`, in the existing plain-language voice.

## 11. Risks

| Risk | Mitigation |
|---|---|
| Menu bar arrangement lost | `hasValidStatusBar` counts the strip; hide, never remove; no existing `autosaveName` changes |
| Popover layout crash | `sizingOptions = []` plus explicit `popover.contentSize`; rows are a snapshot taken at open; every action closes the popover first, so content never mutates while shown |
| Right click hits the wrong account | Cell hit-test feeds `showContextMenu(identityOverride:)`; guarded event read |
| Bar and number disagree | One snapshot-first resolution per profile, passed to both |
| Strip width flapping | 3-point hysteresis, owned by `StatusBarUIManager`, pruned and cleared |
| Pointer-only row actions | Buttons always present in the view and accessibility tree; hover changes opacity only |
| Truncated locales | Fit test at 272pt minus the action cluster, 9 locales |
| MainActor deinit double-free | New helpers are structs/enums with no `deinit`; any class needing one is `nonisolated` |
| Two credentials collapsed | Disc vs punched ring, asserted by fingerprint; tooltip and label name the credential |

## 12. Step order

1. Models, constants, `DataStore` accessors + test 5.
2. `HealthStripLayout` + `HealthStripNumbers` + tests 1, 2.
3. `MenuBarIconRenderer.createHealthStrip` + test 3.
4. `StatusBarUIManager`: strip lifecycle, `hasValidStatusBar`, button lookups, hysteresis + tests
   4, 6.
5. `MenuBarManager`: layout read, click routing, `showContextMenu(identityOverride:)`, the four
   recompute guards, `refreshAllSelectedProfilesFromUI`.
6. `HealthStripAccountsView` and its row model + test 7.
7. Settings pickers and the three disabled-state hints.
8. Localization (12 keys × 9 locales) + test 8 + `scripts/validate_localizations.sh`.
9. `docs/menu-bar.md` + `CHANGELOG.md`.

## 13. Disputed

One item, cosmetic. **m8's own line numbers are off.** It gives the `DataStore` overflow accessors
as `:154-212` and the overflow keys as `Constants.swift:79-82`. In this checkout
`saveMenuBarOverflowMode` opens at `DataStore.swift:155` (doc comment `:154`) and
`menuBarOverflowMode(in:)` closes at `:213`; the keys are at `Constants.swift:81-83` (section
comment `:80`). This plan uses `:154-213` and `:81-83`. Every other finding was checked against the
source and adopted as written.

---

**Summary**

1. Health strip stays a layout inside multi mode; 27 `displayMode == .multi` comparisons against
   two exhaustive switches make a third enum case the riskier shape.
2. Three blockers closed: `hasValidStatusBar` counts the strip item, Refresh All gets a fan-out
   route outside the captured-target router, right click hit-tests the cell via `identityOverride`.
3. The popover uses the main popover's shape — `sizingOptions = []`, explicit `contentSize`, rows
   snapshotted at open — because the crash was content-derived Auto Layout, not `sizePopover`.
4. Bar and numbers read one snapshot-first source; hysteresis lives on `StatusBarUIManager`, pruned
   and cleared; row actions are always-present icon buttons, not hover-only controls.
5. Eight test suites, 12 new localization keys across 9 locales, `menu.provider.open_profile`
   reused, and nothing changes for anyone who leaves the setting off.
