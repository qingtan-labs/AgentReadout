# AgentReadout

AgentReadout (formerly Gauge for Codex) is an independent native macOS menu bar utility. Some internal identifiers and source-install paths retain the old name for upgrade compatibility.

## Product behavior

- Shows a large localized percentage and a slim progress bar in the menu bar.
- Shows each available usage window in the menu and uses the most constrained window for the menu bar value.
- Shows recognized membership labels beside service names in the menu and medium/large widgets (for example Plus, Pro 5× / 20×, Claude Pro, Max 5× / 20×). The menu bar and small widgets stay compact. Codex uses the quota response's `planType`, with verified official-client labels for `prolite` and `pro`; unverified Pro variants remain generic Pro without an inferred multiplier. Claude uses explicit sign-in metadata. Desktop samples are labeled only when their organization matches a recent local account profile. Unknown plans are omitted; membership lookup adds no network requests.
- A compact Codex / Claude switch at the top selects the menu-bar C/A provider in one click (or Command-1 / Command-2), with a checkmark for the current choice. Normal clicks keep the menu open; connecting Claude still requires consent. Both quota cards remain visible, with actual periods, plans, sources and reset times; widgets set to follow the menu bar continue to follow this choice.
- The top-right refresh arrow (Command-R) refreshes enabled services without closing the menu, shows busy state, and prevents duplicate requests. The gear (Command-comma) opens a small General / Appearance & Language / Services / Updates & About window. Appearance can follow macOS or use Light/Dark; language can follow macOS or use Simplified Chinese/English. Menus and windows update immediately; native widgets request a system refresh. Manual quota is under Advanced in Services. Automatic update checks remain at most daily.
- Trends & Usage puts Daily Tokens first. Codex official data refreshes at launch, about every 30 minutes and on demand to power the native widget; the existing Claude Code statistics cache is read only while the statistics window is open. No conversation-log scans or separately stored daily history. Optional 24-hour quota history remains a separate tab; recording defaults off for new users.
- Records up to 24 hours of normalized quota samples in five-minute buckets, with optional recording and clearing. Offline gaps and resets break the line. Optional low-quota notifications (off by default, system authorization required) trigger at 20% / 10% / empty, without sounds or duplicate thresholds within a known window. Stale/expired samples cannot trigger alerts.
- Daily Tokens offers Today / 3d / 7d / 30d charts with exact values on hover, source dates, and explicit unavailable states. Codex also exposes five official cumulative metrics; they do not change with the chart filter. Claude cache coverage is local, not account-wide. Prices and inferred cache ratios are omitted.
- Settings → General includes launch at login. New installations default off, upgrades preserve the existing choice. Settings → Services → Advanced lets either Codex or Claude use temporary manual remaining quota for a 5-hour or 7-day period, with a selectable reset date and time to the second or an explicit unknown option. Other periods are preserved, manual values are labelled, and a successful automatic sync replaces them. Manual Claude data does not enable credential access.
- Displays both a localized countdown and an exact reset date in the current time zone.
- Refreshes at launch, every 60 seconds, when the menu opens after becoming stale, after wake, and immediately after a reset.
- Keeps the last successful value on transient failures and labels data older than five minutes as stale.
- Offers a compact percentage-only mode when menu bar space is limited.
- Includes native small, medium, and large WidgetKit desktop widgets on macOS 14+, plus the draggable floating widget on macOS 12–13 and as a legacy option.
- A separate Daily Tokens desktop widget comes in Small (today and seven-day spark chart), Medium (today, seven days, lifetime and daily peak), and Large (all five official cumulative metrics plus data freshness). Clicking any size opens Trends & Usage directly on Daily Tokens. The Large chart has extra vertical space above a lightweight, unboxed metric summary. Compact chart scales show the seven-day maximum and zero; Medium and Large also show the midpoint. Missing source days remain blank rather than showing a fabricated zero, and unavailable Today is shown once rather than as both a dash and a message.
- Desktop Widget Content can follow the menu bar, show only Codex or Claude, or show both. Native small widgets highlight the most constrained quota, medium widgets show both five-hour and seven-day progress for each service, and large widgets add countdowns, complete reset dates, and sync status. Missing windows and reset times are explicitly identified; percentages always mean remaining quota. The floating widget also supports Large (344 × 344), with adaptive quota columns, per-service connection/sync hints, saved size/position, and the existing desktop/transparent appearance behavior. Small and Medium retain their compact layouts.
- Both widget types lay out actual quota windows dynamically: a single window uses the available width, manual values remain visible, and an unconnected service shows setup/sync guidance instead of a false zero. Missing periods never imply a subscription tier or unlimited access.
- Checks for releases daily by default, can be disabled, and supports manual or verified automatic installation. Release packages include `update.json` (version, internal build, archive, SHA256), so newer builds under the same 1.0.1 version can be detected. Existing installations without this support need one manual upgrade first. Failed replacements attempt to restore/relaunch the previous app; a successful replacement moves the backup to Trash.
- Supports English, Simplified Chinese, Japanese, and Spanish.
- Supports both Apple Silicon and Intel Macs running macOS 12 or later.
- Sends no telemetry.

## Data source and compatibility

AgentReadout starts the `codex app-server --stdio` executable installed with Codex and requests the read-only `account/rateLimits/read` method. It prefers the exact Codex bucket, supports primary and secondary windows, and keeps compatibility with older response shapes.

This is a local integration boundary rather than a documented public API. A future Codex update may require an adapter update. Manual entry remains available as a fallback.

Optional Claude support first reads Claude Desktop's local `plan-usage-history.json` (five-hour/seven-day usage percentages and sample time). If that sample is older than 15 minutes, an existing local Claude OAuth authorization can query Anthropic's usage endpoint. The endpoint is not a documented public API. Desktop cache values have no reset timestamps; samples older than 24 hours are rejected. A failed refresh keeps the last value visibly stale. See [privacy details](../PRIVACY.md).

AgentReadout does not read browser cookies, passwords, or conversation logs, and does not request a model response. Daily Token statistics use Codex's official daily aggregates and an existing Claude Code statistics cache when available; they do not create a separate usage history. Claude Code OAuth access tokens are used only in memory for direct Anthropic usage requests after the user enables Claude. It is not affiliated with or endorsed by OpenAI or Anthropic.

## Build and test

`zsh ./test-menu-insights.sh` renders the production menu and statistics UI in light/dark, connected/missing/stale/disabled/empty states. Regression tests also cover quota gaps, notification deduplication and official daily aggregates. The separate statistics window and per-service card organization take interaction inspiration from [QuotaLens](https://github.com/mangiapanejohn-dev/QuotaLens); this is an independent implementation without its token storage or model-probe requests.

    cd quota-overlay
    ./build.sh

The build creates `build/Gauge for Codex.app`, validates localizations, runs parser tests, signs nested code ad hoc, and verifies Universal 2 architectures and signatures. With full Xcode and XcodeGen it embeds a WidgetKit extension; with Command Line Tools alone it builds only the menu-bar app and floating-widget fallback. Published releases require the native extension. An older installed WidgetKit extension remains Codex-only until replaced by a build containing the new dual-provider extension. After installing the app, launch it once, then add the native widget from macOS **Edit Widgets**.

When changing widget families, gallery metadata, or localization, increment the internal `CFBundleVersion` in both Info.plists and `CURRENT_PROJECT_VERSION` in `widget/project.yml`, even when the public version stays 1.0.1. Reusing build 8 left the old two-size descriptor cached on the development Mac while new layouts rendered. Verify the installed widget in the actual system gallery, not only the source or offscreen previews; do not clear the global widget database or change the widget kind as a workaround.

To inspect the production SwiftUI layouts without changing the desktop, compile `widget/GaugeWidget.swift` and `widget/WidgetPreview.swift` together with `swiftc -parse-as-library -D WIDGET_PREVIEW -framework AppKit -framework SwiftUI -framework WidgetKit`. Run the resulting executable with an output directory. It renders all three sizes with sample, missing, and single-service data in light, dark, and simulated tinted appearances; actual wallpaper tint remains controlled by WidgetKit.

Settings → General → Quota style switches between bars and rings across menu cards, native widgets and floating widgets. The compact menu-bar indicator is unchanged. Bars are the default; the choice is persisted and included in the native widget snapshot. macOS controls the actual WidgetKit refresh timing.

Run `zsh ./test-native-widget.sh` for both styles at all three native widget sizes, including dark, light, simulated tint, international copy and quota boundaries. Run `zsh ./test-floating-widget.sh` to check the production AppKit models and menu entry, and render 198 offscreen previews across both styles and all three sizes. Fixtures cover both periods, weekly-only, unconnected services, sync failures with cached values, manual data, and single-service mode. No account reads, preference writes, or desktop windows are involved. These are layout previews, not a substitute for actual desktop focus/drag testing.

Run `zsh ./test-regressions.sh` for native timeline/staleness, duration classification, regional dates, same-build release metadata, and injected updater failure tests. The host requests WidgetKit reloads on quota changes and explicit user actions, and supplies future timeline entries for countdown/staleness/reset transitions. Background reload requests are coalesced; macOS retains control of actual refresh timing.

Installation stops only the extension executable inside this app bundle and re-registers this app with LaunchServices before relaunch. This avoids retaining a running extension from an older build; no global widget database reset is performed.

## Install for the current user

    ./install.sh

The installer places the app at `~/Applications/Gauge for Codex.app` and registers the per-user LaunchAgent `com.qingtanlabs.gaugeforcodex`. It opens the app after installation but preserves the login-startup choice; new installations use RunAtLoad=false.
