# AirPods toggle helper
# Usage:
#   airpods    # toggle connect/disconnect
#   ap         # same as above
#
# To find your device MAC address:
#   blueutil --paired | grep -i airpods
#
# Device MACs are machine-local; set AIRPODS_MAC in ~/.config/dotfiles/devices.zsh

_airpods_toggle() {
  if ! command -v blueutil >/dev/null 2>&1; then
    echo "blueutil is not installed. Install with: brew install blueutil" >&2
    return 1
  fi

  local devices_file="$HOME/.config/dotfiles/devices.zsh"
  [[ -f "$devices_file" ]] && source "$devices_file"

  local _airpods_device="$AIRPODS_MAC"
  if [[ -z "$_airpods_device" ]]; then
    echo "[INFO] create ~/.config/dotfiles/devices.zsh with AIRPODS_MAC=<mac> (see: blueutil --paired)" >&2
    return 1
  fi

  local connected
  connected=$(blueutil --is-connected "$_airpods_device" 2>/dev/null)

  if [[ "$connected" == "1" ]]; then
    blueutil --disconnect "$_airpods_device" && \
      echo "AirPods disconnected" || \
      echo "Failed to disconnect AirPods"
  else
    blueutil --connect "$_airpods_device" && \
      echo "AirPods connected" || \
      echo "Failed to connect AirPods"
  fi
}

# Public commands
airpods() {
  _airpods_toggle "$@"
}

alias ap="airpods"
