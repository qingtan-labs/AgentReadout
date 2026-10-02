# Changelog

All notable changes are documented here.

## 1.0.1 - 2026-10-01

- Added a draggable desktop widget with small and medium layouts, saved position and visibility, and system-aware backgrounds.
- Refined the widget to macOS-sized proportions with a frosted appearance, the compact Windows brand mark, and exact reset times for each quota window.
- Replaced the fixed widget tint with a translucent neutral surface that preserves the current wallpaper colors.
- Honors macOS Reduce Transparency with an opaque system background.
- Added manual update checks and daily automatic checks with an off switch.
- Added verified ZIP updates with SHA-256, bundle identity, version, code-signing checks, and rollback protection.
- Localized the widget and update controls in English, Simplified Chinese, Japanese, and Spanish.
- Kept the menu-bar app and desktop widget compatible with macOS 12 and later.

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
