# Gauge for Codex

Gauge for Codex is an independent native macOS menu bar utility that keeps Codex usage visible without attaching UI to a Codex window.

## Product behavior

- Shows a large localized percentage and a slim progress bar in the menu bar.
- Shows each available usage window in the menu and uses the most constrained window for the menu bar value.
- Displays both a localized countdown and an exact reset date in the current time zone.
- Refreshes at launch, every 60 seconds, when the menu opens after becoming stale, after wake, and immediately after a reset.
- Keeps the last successful value on transient failures and labels data older than five minutes as stale.
- Offers a compact percentage-only mode when menu bar space is limited.
- Includes small and medium macOS 14 desktop widgets backed by shared local data.
- Checks for releases daily by default, can be disabled, and supports manual or verified automatic installation.
- Supports English, Simplified Chinese, Japanese, and Spanish.
- Supports both Apple Silicon and Intel Macs running macOS 12 or later.
- Sends no telemetry.

## Data source and compatibility

Gauge for Codex starts the `codex app-server --stdio` executable installed with Codex and requests the read-only `account/rateLimits/read` method. It prefers the exact Codex bucket, supports primary and secondary windows, and keeps compatibility with older response shapes.

This is a local integration boundary rather than a documented public API. A future Codex update may require an adapter update. Manual entry remains available as a fallback.

Gauge for Codex does not read browser cookies, conversation content, or passwords, and does not request a model response. It is not affiliated with or endorsed by OpenAI.

## Build and test

    cd quota-overlay
    ./build.sh

With Xcode 15 or later, the build creates `build/Gauge for Codex.app` with an embedded Universal 2 WidgetKit extension. Older Command Line Tools build and test the menu app only. The script validates localizations, runs parser tests, signs nested code ad hoc, and verifies architectures and signatures.

## Install for the current user

    ./install.sh

The installer places the app at `~/Applications/Gauge for Codex.app` and registers the per-user LaunchAgent `com.qingtanlabs.gaugeforcodex`.
