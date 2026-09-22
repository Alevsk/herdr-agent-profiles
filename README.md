# Herdr Agent Profiles & Subscriptions 👤

A lightweight background plugin that visually injects the active subscription and account profile of your agents directly into the Herdr sidebar.

If you juggle multiple accounts (e.g. personal vs. work subscriptions for Claude, Codex, or Grok), Herdr natively only displays the agent's name (e.g., `claude`). This plugin detects the exact account/subscription tied to each pane and overwrites the metadata to show rich identifiers like:
- `claude (max) · alevsk@gmail.com`
- `codex (team) · alevsk@gmail.com`
- `grok (tier 1) · alevsk@gmail.com`

## Supported Agents

- **Claude:** Reads `claude auth status` (Email + Subscription Type)
- **Codex:** Decodes `~/.codex/auth.json` JWT (Email + Plan Type)
- **Grok:** Reads `~/.grok/auth.json` (Email + Tier)
- **Antigravity (agy):** Reads `~/.gemini/google_accounts.json` (Active Account)
- **OpenCode:** Reads `~/.config/opencode/opencode.json` (Provider Backend)

## Installation

Install the plugin directly from GitHub:

```bash
herdr plugin install alevsk/herdr-agent-profiles
```

Reload the Herdr server to initialize the background hook:

```bash
herdr server reload-config
```

That's it! The plugin requires zero manual configuration. 

## Architecture

This plugin uses an **Event-Driven Daemon** architecture. It does not run a continuous polling loop in the background. Instead, it hooks directly into:
1. `startup`: When Herdr boots or reloads, it scans all active agents and updates their sidebar labels.
2. `pane.agent_detected`: Whenever a new agent is spawned in a pane, it specifically targets that single pane to resolve its profile instantly.

It uses the `herdr pane report-metadata <pane> --source "agent-profiles" --token "provider=..."` API to inject the resolved strings.

## License

MIT
