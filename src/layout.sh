#!/usr/bin/env bash

VERSION="0.0.3";

export ROOT="/usr/lib/bsp-layout";
source "$ROOT/utils/desktop.sh";
source "$ROOT/utils/layout.sh";
source "$ROOT/utils/state.sh";

LAYOUTS="$ROOT/layouts";

HELP_TEXT="
Usage: bsp-layout command [args]

Commands:
  set <layout> [desktop_selector] -- [options]      - Will apply the layout to the selected desktop
  once <layout> [desktop_selector] -- [options]     - Will apply the layout on the current set of nodes
  get <desktop_selector>                            - Will print the layout assigned to a given desktop
  cycle [options]                                   - Will apply the layout on the current set of nodes
  remove <desktop_selector>                         - Will disable the layout
  layouts                                           - Will list all available layouts
  version                                           - Displays the version number of the tool
  help                                              - See this help menu

Layout options:
  tall,wide,rtall,rwide
    --master-size 0.6         Set the master window size

Cycle options:
  cycle
    --layouts wide,tall,tiled
    --desktop 1
";

# Layouts provided by bsp out of the box
BSP_DEFAULT_LAYOUTS="tiled\nmonocle";

# Kill old layout process
kill_layout() {
  old_pid="$(get_desktop_options "$1" | valueof pid)";
  kill $old_pid 2> /dev/null || true;
}

remove_listener() {
  desktop=$1;
  [[ -z "$desktop" ]] && desktop=$(get_focused_desktop);

  kill_layout "$desktop";

  # Reset process id and layout
  set_desktop_option $desktop 'layout' "";
  set_desktop_option $desktop 'pid'    "";
}

get_layout_file() {
  local layout_file="$LAYOUTS/$1.sh"; shift;
  # GUARD: Check if layout exists
  [[ ! -f $layout_file ]] && echo "Layout does not exist" && exit 1;
  echo "$layout_file";
}

setup_layout() { bash "$(get_layout_file $1)" setup $*; }
run_layout() { bash "$(get_layout_file $1)" run $*; }

get_layout() {
  local layout=$(get_desktop_options "$1" | valueof layout);
  echo "${layout:-"-"}";
}

list_layouts() {
  echo -e "$BSP_DEFAULT_LAYOUTS"; ls "$LAYOUTS" | sed -e 's/\.sh$//';
}

cycle_layouts() {
  local layouts=$(list_layouts);
  local desktop_selector=$(get_focused_desktop);
  while [[ $# != 0 ]]; do
    case $1 in
      --layouts)
          if [[ ! -z "$2" ]]; then
            layouts=$(echo "$2" | tr ',' '\n');
          fi;
          shift;
      ;;
      --desktop)
        desktop_selector="$2";
        shift;
      ;;
      *) ;;
    esac;
    shift;
  done;

  local current_layout=$(get_layout "$desktop_selector");
  local next_layout=$(echo -e "$layouts" | grep "$current_layout" -A 1 | tail -n 1);
  if [[ "$next_layout" == "$current_layout" ]] || [[ -z "$next_layout" ]]; then
    next_layout=$(echo -e "$layouts" | head -n 1);
  fi;

  echo "$current_layout:$next_layout";
  start_listener "$next_layout" "$desktop_selector";
}

start_listener() {
  layout=$1; shift;
  selected_desktop=$1; shift;
  [[ "$selected_desktop" == "--" ]] && selected_desktop="";

  args=$@;

  # Set selected desktop to currently focused desktop if option is not specified
  [[ -z "$selected_desktop" ]] && selected_desktop=$(get_focused_desktop);

  bspc desktop "$selected_desktop" -l tiled;

  # If it is a bsp default layout, set that
  if (echo -e "$BSP_DEFAULT_LAYOUTS" | grep "^$layout$"); then
    remove_listener "$selected_desktop";
    set_desktop_option $selected_desktop 'layout' "$layout";
    bspc desktop "$selected_desktop" -l "$layout";
    exit 0;
  fi

  initialize_layout() { setup_layout $layout $args 2> /dev/null || true; }
  recalculate_layout() { run_layout $layout $args 2> /dev/null || true; }

  # Then listen to node changes and recalculate as required
  bspc subscribe node_{add,remove,transfer}  | while read line; do
    event=$(echo "$line" | awk '{print $1}');
    arg_index=$([[ "$event" == "node_transfer" ]] && echo "6" || echo "3");
    desktop_id=$(echo "$line" | awk "{print \$$arg_index}");
    desktop_name=$(get_desktop_name_from_id "$desktop_id");

    initialize_layout;
    [[ "$desktop_name" = "$selected_desktop" ]] && \
      if [[ "$event" == "node_transfer" ]]; then
        local source=$(echo "$line" | awk '{print $3}');
        local dest=$(echo "$line" | awk '{print $3}');

        [[ "$source" != "$dest" ]] && recalculate_layout;
      else
        recalculate_layout;
      fi;
  done &

  LAYOUT_PID=$!; # PID of the listener in the background
  disown;

  # Kill old layout
  kill_layout $selected_desktop;

  # Set current layout
  set_desktop_option $selected_desktop 'layout' "$layout";
  set_desktop_option $selected_desktop 'pid'    "$LAYOUT_PID";

  # Setup
  initialize_layout;

  # Recalculate styles as soon as they are set if it is on the selected desktop
  if [[ "$(get_focused_desktop)" == "$selected_desktop" ]]; then
    # Calculate layout twice to ensure rotations are corrected from previous layout
    recalculate_layout;
    recalculate_layout;
  fi;

  echo "[$LAYOUT_PID]";
}

reload_layouts() {
  list_desktops | while read desktop; do
    layout=$(get_desktop_options "$desktop" | valueof layout);
    [[ ! -z "$layout" ]] && start_listener $layout $desktop;
  done;
}

# Check for dependencies
for dep in bc bspc; do
  !(which $dep >/dev/null 2>&1) && echo "[Missing dependency] bsp-layout needs $dep installed" && exit 1;
done;

action=$1; shift;

case "$action" in
  reload)     reload_layouts ;;
  once)       run_layout $* ;;
  set)        start_listener "$@" ;;
  cycle)      cycle_layouts "$@" ;;
  get)        get_layout "$@" ;;
  remove)     remove_listener "$1" ;;
  layouts)    list_layouts ;;
  help)       echo -e "$HELP_TEXT" ;;
  version)    echo "$VERSION" ;;
  *)          echo -e "$HELP_TEXT" && exit 1 ;;
esac
