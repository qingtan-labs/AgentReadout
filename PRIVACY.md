# Privacy

AgentReadout (formerly Gauge for Codex) is designed to keep its own data handling minimal. Its bundle identifier stays unchanged for upgrade compatibility.

## Data the app reads

The app locates a Codex executable already installed on the Mac and requests the account rate-limit summary through the local `app-server` stdio interface. The response is normalized to usage percentages, reset timestamps, window durations, and an explicit plan label when available.

Claude support is optional and disabled until you enable Claude usage in the menu. The app first reads only `plan-usage-history.json` from Claude Desktop's local application-support directory. This file contains sampled five-hour and seven-day utilization percentages and sample times, but not reset times or conversations. If the sample is older than 15 minutes, the app can read an existing local Claude OAuth access token from the macOS Keychain service `Claude Code-credentials` or `~/.claude/.credentials.json` and request usage directly from Anthropic. It never reads Claude Desktop browser cookies or its private login cache. It does not store the OAuth token.

## Data the app stores

Membership labels are read from Codex's quota response or Claude Code's existing OAuth metadata. When displaying a Claude Desktop sample, the app may consult only the `oauthAccount` profile fields in `~/.claude.json`; a plan is used only if the organization matches the sample and the profile is less than seven days old. No extra network request is made for membership lookup. Account identifiers are compared in memory only and are not saved or sent to widgets. Unknown plans are omitted rather than inferred from usage or payment method.

The following values are stored in the app's macOS UserDefaults domain:

- normalized usage-window percentages;
- recognized membership labels (not account identifiers or emails);
- reset timestamps and window durations;
- the last successful refresh time;
- the selected menu-bar and desktop-widget display modes;
- the selected provider and whether optional Claude support is enabled;
- whether automatic update checks are enabled and the time of the last check.
- up to 24 hours of normalized quota samples (provider, observed time, period, remaining percentage, reset time), in five-minute buckets; this recording can be disabled or cleared independently;
- low-quota notification preferences and per-window threshold deduplication state. Notifications are off by default and require system authorization. No sound is requested.

## Daily Token activity

While AgentReadout is running, it requests `account/usage/read` through the locally installed Codex app-server at launch, about every 30 minutes, and on manual refresh, so the Daily Token desktop widget can update without opening the statistics window. Only official daily token buckets and five numeric summary fields are retained: lifetime tokens, peak daily tokens, longest single turn duration, current streak and longest streak. Thread-level details are discarded. This request can contact OpenAI using the existing Codex sign-in.

When the statistics window is open, the page reads only an existing Claude Code `stats-cache.json` under `CLAUDE_CONFIG_DIR` or `~/.claude`, limited to 8 MB and the `dailyModelTokens` aggregate. Background widget updates do not read this Claude cache. AgentReadout does not create or rebuild it. Its coverage follows the source's local records and may include previous accounts on this Mac; it is not an account-wide Claude total. No session logs are scanned. Missing, malformed or unavailable source data stays unavailable, rather than becoming a fabricated zero. Dates and update coverage are shown as supplied by the source. AgentReadout does not save a separate daily usage history; the WidgetKit extension may cache one latest normalized snapshot for offline display. No prices are shown and no cache-hit ratio is inferred from daily totals. The separate, optional 24-hour quota trend still uses AgentReadout's own samples and is off by default for new installs.

Login startup is controlled by a per-user LaunchAgent property list. Fresh installs default to off; upgrades preserve the existing RunAtLoad choice. Changing it affects the next login and does not terminate the currently running app.

## Data the app does not collect

AgentReadout does not collect or persist prompts or conversation content, or read browser cookies, passwords, or API keys. Daily statistics do not scan conversation logs. With Claude support enabled, it may read an existing Claude Code OAuth access token solely to make the Anthropic usage request described below; the token is not stored or exposed to the widget. It has no analytics SDK, advertising SDK, telemetry endpoint, crash-reporting service, or developer-operated backend.

## Network behavior

AgentReadout makes no analytics or telemetry requests. When update checking is enabled, it contacts the public GitHub Releases API for `qingtan-labs/GaugeForCodex` at most once a day. A newer release's Universal ZIP and `SHA256SUMS` are downloaded only for automatic installation. The app compares the published SHA-256 value, expected bundle identifier and version, and the bundle's code-signing integrity before replacement. Automatic checking can be disabled from the menu.

On macOS 14+, native widgets ask the running menu-bar app for normalized data over `127.0.0.1:38429`. The server listens only on the local loopback interface and serves quota percentages, window durations, reset timestamps, last-update time, recognized membership labels, the latest seven Codex daily Token aggregates and the five numeric official summary metrics. It does not serve credentials, account identifiers, email addresses, prompts, conversation content, or raw Codex responses. Other programs running under the same Mac may reach this local endpoint, so these quota and Token aggregates should not be treated as secret data.

The locally installed Codex component may communicate with OpenAI using the account already configured on the Mac in order to return current usage data. That communication is governed by the user's OpenAI agreement and settings.

When Claude support is enabled and the local Desktop sample is not recent, an existing Claude Code sign-in may be used to call `https://api.anthropic.com/api/oauth/usage`. This is not a documented public usage API, so it may change or stop working. The OAuth token is sent only to Anthropic over HTTPS. If this request is unavailable, the app can show a Desktop sample from the last 24 hours as stale; older samples are not presented as current quota. Claude Desktop's history does not include reset times, and the app does not invent them.

## Manual values and removal

Values entered through the manual fallback stay in the same local UserDefaults domain. Uninstalling the application does not automatically erase preferences; they can be removed separately with:

```bash
defaults delete com.qingtanlabs.gaugeforcodex
defaults delete group.com.qingtanlabs.gaugeforcodex
```
