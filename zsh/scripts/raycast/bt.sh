#!/bin/zsh

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Bluetooth Toggle
# @raycast.mode silent

# Optional parameters:
# @raycast.packageName Bluetooth
# @raycast.icon 🎧

# Arguments:
# @raycast.argument1 { "type": "text", "placeholder": "airpods|ap|mouse", "optional": true }

################################################################################
# CONFIG – device MACs are machine-local, set them in ~/.config/dotfiles/devices.zsh
################################################################################

DEVICES_FILE="$HOME/.config/dotfiles/devices.zsh"

[[ -f "$DEVICES_FILE" ]] && source "$DEVICES_FILE"

if [[ -z "$AIRPODS_MAC" && -z "$MOUSE_MAC" ]]; then
  echo "[INFO] create ~/.config/dotfiles/devices.zsh with AIRPODS_MAC and MOUSE_MAC (from \`blueutil --paired\`)" >&2
  exit 1
fi

# Where to store the last-used device (airpods|mouse)
STATE_DIR="$HOME/.config/bt-toggle"
STATE_FILE="$STATE_DIR/last_device"

################################################################################
# Helper functions
################################################################################

fail() {
  echo "$1" >&2
  exit 1
}

ensure_blueutil() {
  if ! command -v blueutil >/dev/null 2>&1; then
    fail "blueutil not found. Install with: brew install blueutil"
  fi
}

save_last_device() {
  local device="$1"
  mkdir -p "$STATE_DIR"
  echo "$device" > "$STATE_FILE"
}

get_last_device() {
  [[ -f "$STATE_FILE" ]] || return 1
  local d
  d=$(<"$STATE_FILE")
  [[ -n "$d" ]] || return 1
  echo "$d"
  return 0
}

toggle_device() {
  local mac="$1"
  local label="$2"

  if [[ -z "$mac" ]]; then
    fail "No MAC address configured for $label."
  fi

  local connected
  connected=$(blueutil --is-connected "$mac" 2>/dev/null)

  if [[ "$connected" == "1" ]]; then
    if blueutil --disconnect "$mac" >/dev/null 2>&1; then
      echo "Disconnected $label"
    else
      fail "Failed to disconnect $label ($mac)"
    fi
  else
    if blueutil --connect "$mac" >/dev/null 2>&1; then
      echo "Connected $label"
    else
      fail "Failed to connect $label ($mac)"
    fi
  fi
}

################################################################################
# Main
################################################################################

ensure_blueutil

# Raycast passes the first argument as $1; CLI usage is the same:
#   bt              -> toggle last device (or AirPods if none)
#   bt airpods|ap   -> toggle AirPods
#   bt mouse        -> toggle mouse

arg="$1"
arg="${arg:l}"   # lowercase

device_key=""
device_mac=""
device_label=""

if [[ -z "$arg" ]]; then
  # No argument: use last device, or fallback to airpods
  if last=$(get_last_device 2>/dev/null); then
    device_key="$last"
  else
    device_key="airpods"
  fi
else
  case "$arg" in
    airpods|ap)
      device_key="airpods"
      ;;
    mouse)
      device_key="mouse"
      ;;
    *)
      fail "Unknown device '$arg'. Use: airpods|ap|mouse (or no arg for last used)."
      ;;
  esac
fi

case "$device_key" in
  airpods)
    device_mac="$AIRPODS_MAC"
    device_label="AirPods"
    ;;
  mouse)
    device_mac="$MOUSE_MAC"
    device_label="Mouse"
    ;;
  *)
    fail "Invalid device key: $device_key"
    ;;
esac

save_last_device "$device_key"
toggle_device "$device_mac" "$device_label"
