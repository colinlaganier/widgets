#!/bin/bash
# Interactive builder for the desktop widgets.
# Pick widgets from a checkbox list (up/down to move, space to toggle,
# enter to build, esc to quit), build them via each widget's own build.sh,
# and optionally register the built apps as Login Items.
#
# Non-interactive: ./build.sh --all [--login]   builds everything.
set -euo pipefail
cd "$(dirname "$0")"

WIDGET_DIRS=(azure claude github hackernews wandb)
WIDGET_APPS=(AzureWidget.app ClaudeUsageWidget.app GitHubWidget.app HackerNewsWidget.app WandbWidget.app)
WIDGET_NAMES=("Azure" "Claude Usage" "GitHub" "Hacker News" "W&B")
COUNT=${#WIDGET_DIRS[@]}

selected=()
for ((i = 0; i < COUNT; i++)); do selected[i]=0; done

add_login_item() {
    local app_path="$1"
    local item_name
    item_name="$(basename "$app_path" .app)"
    osascript >/dev/null <<EOF
tell application "System Events"
    if exists login item "$item_name" then delete login item "$item_name"
    make login item at end with properties {path:"$app_path", hidden:false}
end tell
EOF
    echo "  Added to Login Items: $item_name"
}

cursor=0
msg=""
MENU_LINES=$((COUNT + 2))

draw_menu() {
    printf 'Select widgets to build  (↑/↓ move, space toggle, enter build, esc quit)\033[K\n'
    for ((i = 0; i < COUNT; i++)); do
        local mark=" " pointer="  "
        [[ ${selected[i]} -eq 1 ]] && mark="x"
        [[ $i -eq $cursor ]] && pointer="❯ "
        printf "%s[%s] %-12s (%s)\033[K\n" "$pointer" "$mark" "${WIDGET_NAMES[i]}" "${WIDGET_DIRS[i]}"
    done
    printf '%s\033[K\n' "$msg"
}

# --- flags ---------------------------------------------------------------
auto_all=0
auto_login=0
for arg in "$@"; do
    case "$arg" in
        -a|--all)   auto_all=1 ;;
        --login)    auto_login=1 ;;
        -h|--help)
            echo "Usage: $0 [--all [--login]]"
            echo "  --all    build every widget without prompting"
            echo "  --login  with --all: also add built widgets to Login Items"
            exit 0 ;;
        *) echo "Unknown option: $arg (try --help)" >&2; exit 1 ;;
    esac
done

# --- selection -----------------------------------------------------------
if [[ $auto_all -eq 1 ]]; then
    for ((i = 0; i < COUNT; i++)); do selected[i]=1; done
else
    if [[ ! -t 0 ]]; then
        echo "Interactive menu needs a terminal; use --all for non-interactive builds." >&2
        exit 1
    fi
    # bash 3.2 (macOS default) rejects fractional read timeouts
    ESC_TIMEOUT=0.05
    [[ ${BASH_VERSINFO[0]} -lt 4 ]] && ESC_TIMEOUT=1
    tput civis
    trap 'tput cnorm' EXIT
    draw_menu
    while true; do
        IFS= read -rsn1 key
        case "$key" in
            $'\x1b')
                seq=""
                IFS= read -rsn2 -t "$ESC_TIMEOUT" seq || true
                case "$seq" in
                    '[A') cursor=$(( (cursor + COUNT - 1) % COUNT )) ;;
                    '[B') cursor=$(( (cursor + 1) % COUNT )) ;;
                    '')   exit 0 ;;  # bare esc
                esac ;;
            ' ')
                selected[cursor]=$((1 - selected[cursor]))
                msg="" ;;
            '')  # enter
                any=0
                for ((i = 0; i < COUNT; i++)); do [[ ${selected[i]} -eq 1 ]] && any=1; done
                if [[ $any -eq 0 ]]; then
                    msg="Nothing selected — toggle at least one widget with space."
                else
                    break
                fi ;;
            q|Q) exit 0 ;;
        esac
        printf '\033[%dA' "$MENU_LINES"
        draw_menu
    done
    tput cnorm
    trap - EXIT
fi

# --- build ---------------------------------------------------------------
built_apps=()
failed=()
for ((i = 0; i < COUNT; i++)); do
    [[ ${selected[i]} -eq 1 ]] || continue
    echo
    echo "==> Building ${WIDGET_NAMES[i]}..."
    if "./${WIDGET_DIRS[i]}/build.sh"; then
        built_apps+=("$PWD/${WIDGET_DIRS[i]}/${WIDGET_APPS[i]}")
    else
        failed+=("${WIDGET_NAMES[i]}")
    fi
done

echo
if [[ ${#failed[@]} -gt 0 ]]; then
    echo "Failed to build: ${failed[*]}" >&2
fi
if [[ ${#built_apps[@]} -eq 0 ]]; then
    echo "No widgets were built."
    exit 1
fi
echo "Built ${#built_apps[@]} widget(s):"
for app in "${built_apps[@]}"; do echo "  $app"; done

# --- login items ---------------------------------------------------------
add_login=""
if [[ $auto_all -eq 1 ]]; then
    [[ $auto_login -eq 1 ]] && add_login="y" || add_login="n"
else
    echo
    read -rp "Add the built widget(s) to Login Items so they start on login? [y/N] " add_login || add_login="n"
fi

if [[ "$add_login" =~ ^[yY] ]]; then
    echo
    for app in "${built_apps[@]}"; do
        add_login_item "$app"
    done
    echo "Done. Manage these under System Settings > General > Login Items."
fi

[[ ${#failed[@]} -eq 0 ]]
