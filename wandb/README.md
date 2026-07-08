# W&B Widget

A small macOS desktop widget (matching the style of the Claude Usage widget) that shows
Weights & Biases runs for a selected project.

- **Running runs**: if any runs are in progress it shows them with elapsed time.
- **Latest runs**: otherwise it shows the five most recent runs with state and age.
- **Project dropdown**: click the gold project name to switch projects. Projects whose
  runs you can't see (restricted team projects) are filtered out of the list.
- Right-click for Refresh, Open in W&B, Open Log, and Quit.

## Auth

Uses the API key stored by `wandb login` in `~/.netrc` (or `WANDB_API_KEY` if set).
No key is stored by the widget itself.

## Build & run

```sh
./build.sh
open WandbWidget.app
```

Polls the W&B GraphQL API every 60 s, with backoff on rate limits. The last successful
response is cached per project so the widget shows data immediately on launch.

Log file: `~/Library/Logs/WandbWidget.log`

## Start at login

System Settings → General → Login Items → add `WandbWidget.app`.
