# Hacker News Widget

A small macOS desktop widget (matching the style of the Claude Usage and W&B widgets)
that shows the top Hacker News headlines.

- **Top stories**: shows 3 headlines at a time, paginated through the top 15 with the
  ‹ › arrows below the list.
- **Click a headline** to open the article (Ask HN posts open the discussion).
  The grey magnifier button on each row opens the comments on Hacker News;
  right-clicking a headline also offers Open Article / Open Comments.
- Right-click the widget for Refresh, Open Hacker News, Open Log, and Quit.

## Build & run

```sh
./build.sh
open HackerNewsWidget.app
```

Polls the official [Hacker News API](https://github.com/HackerNews/API) every hour
(no auth required), with backoff on rate limits; the refresh button forces an update
immediately. The last successful response is cached so the widget shows headlines
immediately on launch.

Log file: `~/Library/Logs/HackerNewsWidget.log`

## Start at login

System Settings → General → Login Items → add `HackerNewsWidget.app`.
