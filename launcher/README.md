# AgentReadout Launcher

The launcher is a small, non-resident companion for AgentReadout:

- It first asks the configured per-user LaunchAgent to start AgentReadout.
- If the LaunchAgent is unavailable, it opens a registered installation or checks `~/Applications` and `/Applications` for both AgentReadout and the legacy app path.
- It never starts Codex itself or the retired standalone pet.
- It uses the same language-neutral gauge icon and supports English, Simplified Chinese, Japanese, and Spanish error messages.

Build output: `build/Gauge for Codex Launcher.app` (legacy build path; display name is AgentReadout Launcher).
