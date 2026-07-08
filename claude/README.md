# Claude Usage Widget

A macOS desktop widget showing your Claude plan usage — current session (5-hour window) and weekly limits for all models — styled to match native Apple desktop widgets (translucent material, SF Pro, rounded 20 pt corners).

![layout] Session gauge on the left, per-limit weekly bars on the right.

## How it works

- Reads your Claude Code OAuth token from the macOS Keychain (`Claude Code-credentials`, the same credential Claude Code itself uses).
- Calls `GET https://api.anthropic.com/api/oauth/usage` (the endpoint behind Claude Code's `/usage`) every 5 minutes and on wake. If the endpoint rate-limits (HTTP 429), the widget keeps showing the last known data and backs off exponentially (10 min → 20 min → … capped at 1 h, honoring `Retry-After`).
- Errors are logged to `~/Library/Logs/ClaudeUsageWidget.log` (right-click → Open Log).
- Renders the `limits` array: `session` (5-hour window), `weekly_all` (all models), and any `weekly_scoped` per-model limits (e.g. Fable).
- Bars turn orange at ≥70 % and red at ≥90 %.

## Build & run

```sh
./build.sh
open ClaudeUsageWidget.app
```

- **Move it**: drag anywhere on the widget — position is remembered.
- **Refresh**: click the ↻ button in the widget's top-right corner (shows a spinner while fetching), or right-click → Refresh. Both bypass the poll schedule.
- **Open Log / Quit**: right-click the widget.
- The last successful response is cached, so the widget shows data immediately after a restart even if the endpoint is temporarily rate-limiting.
- The window sits at desktop level (with your desktop icons), on all Spaces, and never appears in the Dock or app switcher (`LSUIElement`).

## Start at login

System Settings → General → Login Items → add `ClaudeUsageWidget.app`.

## Notes

- If the token expires (widget shows "Auth expired"), just use Claude Code — it refreshes the credential automatically.
- macOS may prompt once for Keychain access on first launch; click **Always Allow**.
