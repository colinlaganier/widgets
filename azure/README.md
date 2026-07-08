# Azure Widget

A small macOS desktop widget (matching the style of the Claude Usage, W&B,
Hacker News, and GitHub widgets) that shows the power state of your Azure
virtual machines and lets you start or shut them down.

- **VM dropdown**: lists every VM you have access to in your default Azure
  subscription (borderless menu, same layout as the W&B widget's project
  picker); the selection is remembered across launches, with the VM's
  resource group shown on the right.
- **Status pill**: below the dropdown, a W&B-style capsule — green while the
  VM is running, gray when stopped or deallocated, and orange with a spinner
  while it is starting or shutting down (polled every 10 s until it settles).
  The VM size is shown next to it (e.g. "NC96ads A100 v4").
- **▶ / ⏻ buttons**: ▶ powers the VM on; ⏻ *deallocates* it
  (`az vm deallocate`), which releases the compute so you stop being billed —
  not just an OS-level stop. Buttons disable while an action is in flight or
  when they don't apply; hover for tooltips.
- **`</>` button**: opens a new VS Code window connected to the VM over
  Remote-SSH (`code --new-window --remote ssh-remote+user@host`, using the
  VM's admin username and its FQDN or public IP). Enabled only while the VM
  is running and has a public address.
- Right-click the widget for Refresh, Open Azure Portal, Open Log, and Quit.

## Auth

The widget shells out to the Azure CLI (`az`), so it uses whatever login the
CLI already has. If the token has expired, the widget shows
"Not logged in — run: az login"; run:

```sh
az login --scope https://management.core.windows.net//.default
```

and hit the refresh button. VMs are listed from the CLI's default
subscription (`az account set -s <name>` to change it).

## Build & run

```sh
./build.sh
open AzureWidget.app
```

Polls `az vm list -d` every 5 minutes (dropping to a 10-second single-VM poll
while the selected VM is transitioning); the refresh button forces an update
immediately. The last successful response is cached so the widget shows VMs
immediately on launch.

Log file: `~/Library/Logs/AzureWidget.log`

## Start at login

System Settings → General → Login Items → add `AzureWidget.app`.
