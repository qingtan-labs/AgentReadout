# Changelog

All notable changes are documented here.

## 1.0.3 - 2026-10-01

- Replaced the certificate-dependent WidgetKit extension with an integrated desktop widget that works in public ad-hoc-signed builds.
- Added draggable small and medium layouts, persistent size/position/visibility, multi-display recovery, and all-Spaces support.
- Added a light system background when Finder is active and a material background while other applications are in front.
- Extended desktop-widget support to macOS 12 and later without requiring Xcode 15 or an Apple Developer certificate.

## 1.0.2 - 2026-10-01

- Attempted to remove the App Group data dependency, but PlugInKit still rejects an unsandboxed WidgetKit extension. Superseded by 1.0.3.

## 1.0.1 - 2026-10-01

- Added native small and medium desktop widgets for macOS 14 or later.
- Added adaptive WidgetKit backgrounds that follow the system's desktop rendering mode.
- Added shared App Group quota snapshots and immediate widget timeline reloads.
- Added manual update checks and daily automatic checks with an off switch.
- Added verified automatic ZIP updates with SHA-256, bundle identity, version, and code-signing checks plus rollback protection.
- Added localized update and widget guidance in English, Simplified Chinese, Japanese, and Spanish.
- Kept the menu-bar app compatible with macOS 12 and later.

## 1.0.0 - 2026-09-08

- Initial public open-source release.
- Added a native Universal 2 macOS menu-bar usage display.
- Added automatic refresh, wake refresh, stale-data handling, and local caching.
- Added multiple usage-window parsing and most-constrained-window selection.
- Added localized reset countdowns and exact local reset times.
- Added full and compact menu-bar display modes plus manual fallback.
- Added English, Simplified Chinese, Japanese, and Spanish localizations.
- Added the original C + terminal-prompt quota-ring icon.
- Added a non-resident optional launcher and legacy preference migration.
