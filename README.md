# AgentReadout

AgentReadout is an open-source, native macOS menu bar app for Codex and Claude quota, reset times, and available daily Token usage. Previously called Gauge for Codex, it keeps the existing bundle identifier, URL scheme, and some build paths so settings and widgets survive an upgrade.

[Website](https://qingtan-labs.github.io/AgentReadout/) · [Latest download](https://github.com/qingtan-labs/AgentReadout/releases/latest) · [简体中文](README.zh-Hans.md)

## Features

- See Codex and Claude quota windows and plan tiers together. The menu bar highlights the most constrained available window. Bars are the default; rings are optional.
- Small, Medium, and Large native Quota and Daily Tokens widgets on macOS 14+, with a floating-widget fallback on macOS 12–13.
- Daily Tokens use existing Codex daily aggregates and lifetime statistics. Claude appears only when an existing client cache is available. Missing data is shown as unavailable; no separate Token history or cost estimate is created.
- Automatic refresh, optional low-quota alerts and 24-hour quota trends, and temporary manual fallback when automatic sync fails.
- Follow system appearance and language or override them. Chinese, English, Japanese, and Spanish are available.
- Settings and necessary quota snapshots remain local. The app does not read conversation bodies or send telemetry.

## Install

Download the Universal DMG or ZIP from [GitHub Releases](https://github.com/qingtan-labs/AgentReadout/releases/latest). Apple silicon and Intel Macs on macOS 12+ are supported. Native WidgetKit desktop widgets require macOS 14+.

Release bundles are **ad-hoc signed, not Apple notarized**. If Gatekeeper blocks the first launch, review the app's origin and allow it manually in System Settings → Privacy & Security. Download only from this repository's Releases and verify the included SHA-256 checksums.

Build and install from source:

```sh
git clone https://github.com/qingtan-labs/AgentReadout.git
cd AgentReadout/quota-overlay
./install.sh
```

The source installer retains the compatibility path `~/Applications/Gauge for Codex.app`. The new DMG/ZIP contains `AgentReadout.app`; existing auto-updated installations keep their previous path but display the new product name. Login startup is off by default for new installations, and upgrades preserve the existing choice.

## Sources and privacy

Codex limits come from the local Codex read-only `account/rateLimits/read` method; Daily Tokens use its existing official daily aggregates. Claude first uses an existing local client usage cache and, only when authorized locally and needed, may request current limits directly from Anthropic. These interfaces can change. Sync failures and stale data are labelled rather than replaced with false zeroes.

There is no project-run account or backend and no telemetry or ad SDK. Update checks contact GitHub; live Claude sync may contact Anthropic. See the [privacy notice](PRIVACY.md) and [technical documentation](quota-overlay/README.md).

AgentReadout is an independent, unofficial utility, not affiliated with or endorsed by OpenAI or Anthropic. Source code and original artwork are available under the [MIT License](LICENSE).
