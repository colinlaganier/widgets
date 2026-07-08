# GitHub Widget

A small macOS desktop widget (matching the style of the Claude Usage, W&B, and
Hacker News widgets) that lists open GitHub issues and pull requests that
involve you — authored, assigned, mentioned, or review-requested.

- **Issues & PRs**: shows 5 items at a time (most recently updated first),
  paginated through the latest 30 with the ‹ › arrows below the list. The
  header shows the total count of open items involving you.
- **Icons**: a green circle marks an issue, a green pull arrow marks a PR
  (gray while the PR is a draft).
- **Click an item** to open it on GitHub; right-clicking also offers
  Open on GitHub / Open Repository.
- Right-click the widget for Refresh, Open GitHub Issues, Open Log, and Quit.

## Auth

No configuration needed: the widget reads the github.com credential that git
already stores in the macOS keychain (`git credential fill`, backed by the
`osxkeychain` helper). If the token is rotated, the widget picks up the new
one on the next refresh after a 401.

## Build & run

```sh
./build.sh
open GitHubWidget.app
```

Polls the [GitHub search API](https://docs.github.com/en/rest/search/search)
(`is:open involves:@me`) every 5 minutes, with backoff on rate limits; the
refresh button forces an update immediately. The last successful response is
cached so the widget shows items immediately on launch.

Log file: `~/Library/Logs/GitHubWidget.log`

## Start at login

System Settings → General → Login Items → add `GitHubWidget.app`.
