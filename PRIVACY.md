# Privacy

Gauge for Codex is designed to keep its own data handling minimal.

## Data the app reads

The app locates a Codex executable already installed on the Mac and requests the account rate-limit summary through the local `app-server` stdio interface. The response is normalized to usage percentages, reset timestamps, and window durations.

## Data the app stores

The following values are stored in the app's macOS UserDefaults domain:

- normalized usage-window percentages;
- reset timestamps and window durations;
- the last successful refresh time;
- the selected menu-bar display mode.
- whether automatic update checks are enabled and the time of the last check.

## Data the app does not collect

Gauge for Codex does not read prompts, conversation content, browser cookies, passwords, or API keys. It has no analytics SDK, advertising SDK, telemetry endpoint, crash-reporting service, or developer-operated backend.

## Network behavior

Gauge for Codex makes no analytics or telemetry requests. When update checking is enabled, it contacts the public GitHub Releases API for `qingtan-labs/GaugeForCodex` at most once a day. A newer release's Universal ZIP and `SHA256SUMS` are downloaded only for automatic installation. The app compares the published SHA-256 value, expected bundle identifier and version, and the bundle's code-signing integrity before replacement. Automatic checking can be disabled from the menu.

On macOS 14+, the native widget asks the running menu-bar app for normalized quota data over `127.0.0.1:38429`. The server listens only on the local loopback interface and serves percentages, window durations, reset timestamps, and last-update time. It does not serve credentials, prompts, conversation content, or raw Codex responses. Other programs running under the same Mac may reach this local endpoint, so quota percentages should not be treated as secret data.

The locally installed Codex component may communicate with OpenAI using the account already configured on the Mac in order to return current usage data. That communication is governed by the user's OpenAI agreement and settings.

## Manual values and removal

Values entered through the manual fallback stay in the same local UserDefaults domain. Uninstalling the application does not automatically erase preferences; they can be removed separately with:

```bash
defaults delete com.qingtanlabs.gaugeforcodex
defaults delete group.com.qingtanlabs.gaugeforcodex
```
