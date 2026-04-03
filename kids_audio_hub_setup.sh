#!/usr/bin/env bash
set -Eeuo pipefail

# Kids Audio Hub setup for Raspberry Pi 5 using external Intel AX210 Bluetooth
# This script prepares the system, installs dependencies, creates helper scripts,
# and installs systemd user services to:
#   - keep nominated Bluetooth headsets connected
#   - create/update a combined PipeWire/Pulse sink called KidsHub
#
# It does NOT pair devices automatically. Pair/trust the headsets first, then rerun
# the script with their MAC addresses.
#
# Example:
#   bash kids_audio_hub_setup.sh \
#     --devices AA:BB:CC:DD:EE:FF,11:22:33:44:55:66,77:88:99:AA:BB:CC \
#     --user pi \
#     --disable-onboard-bt

SCRIPT_NAME="$(basename "$0")"
TARGET_USER="${SUDO_USER:-${USER}}"
DEVICE_MACS=""
SINK_NAME="KidsHub"
DISABLE_ONBOARD_BT=0
SET_DEFAULT_SINK=1
ENABLE_IWL_POWER_TWEAK=0
INSTALL_YTM_DESKTOP=0
FORCE_SAMPLE_RATE="44100"

log() { printf '[%s] %s\n' "$SCRIPT_NAME" "$*"; }
warn() { printf '[%s] WARNING: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }

usage() {
  cat <<USAGE
Usage:
  sudo bash $SCRIPT_NAME [options]

Options:
  --devices MAC1,MAC2[,MAC3]   Comma-separated Bluetooth headset MAC addresses.
  --user USERNAME              Linux user that will run audio apps and user services.
  --sink-name NAME             Combined sink name. Default: KidsHub
  --disable-onboard-bt         Add dtoverlay=disable-bt if not already present.
  --enable-iwl-power-tweak     Add Intel Wi-Fi power tweak file (optional).
  --install-ytm-desktop        Install Flatpak + YouTube Music desktop app.
  --no-default-sink            Do not set combined sink as the default sink.
  --sample-rate HZ             PipeWire/Pulse sample rate. Default: 44100
  -h, --help                   Show this help.

Notes:
  1. Pair and trust each headset first using bluetoothctl or the desktop UI.
  2. Then rerun this script with --devices.
  3. Reboot after first run if you chose --disable-onboard-bt.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --devices)
      DEVICE_MACS="$2"; shift 2 ;;
    --user)
      TARGET_USER="$2"; shift 2 ;;
    --sink-name)
      SINK_NAME="$2"; shift 2 ;;
    --disable-onboard-bt)
      DISABLE_ONBOARD_BT=1; shift ;;
    --enable-iwl-power-tweak)
      ENABLE_IWL_POWER_TWEAK=1; shift ;;
    --install-ytm-desktop)
      INSTALL_YTM_DESKTOP=1; shift ;;
    --no-default-sink)
      SET_DEFAULT_SINK=0; shift ;;
    --sample-rate)
      FORCE_SAMPLE_RATE="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die "Unknown argument: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Run this script with sudo or as root."
id "$TARGET_USER" >/dev/null 2>&1 || die "User '$TARGET_USER' does not exist."
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -d "$TARGET_HOME" ]] || die "Home directory for '$TARGET_USER' not found."

if [[ -n "$DEVICE_MACS" ]]; then
  IFS=',' read -r -a DEVICE_ARRAY <<< "$DEVICE_MACS"
  for mac in "${DEVICE_ARRAY[@]}"; do
    [[ "$mac" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]] || die "Invalid MAC address: $mac"
  done
else
  DEVICE_ARRAY=()
fi

log "Target user: $TARGET_USER"
log "Sink name: $SINK_NAME"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
  bluez bluez-tools pulseaudio-utils pipewire pipewire-pulse wireplumber \
  flatpak pavucontrol jq curl

# Ensure user lingering so user services can start at boot without login.
loginctl enable-linger "$TARGET_USER" || true

# Disable onboard Bluetooth if requested.
if [[ $DISABLE_ONBOARD_BT -eq 1 ]]; then
  CONFIG_FILE="/boot/firmware/config.txt"
  [[ -f "$CONFIG_FILE" ]] || CONFIG_FILE="/boot/config.txt"
  if [[ -f "$CONFIG_FILE" ]]; then
    if ! grep -q '^dtoverlay=disable-bt$' "$CONFIG_FILE"; then
      echo 'dtoverlay=disable-bt' >> "$CONFIG_FILE"
      log "Added dtoverlay=disable-bt to $CONFIG_FILE"
      warn "Reboot required for onboard Bluetooth disable to take effect."
    else
      log "dtoverlay=disable-bt already present in $CONFIG_FILE"
    fi
  else
    warn "Could not find Raspberry Pi config.txt to disable onboard Bluetooth."
  fi
fi

# Optional Intel power tweak.
if [[ $ENABLE_IWL_POWER_TWEAK -eq 1 ]]; then
  mkdir -p /etc/modprobe.d
  cat > /etc/modprobe.d/iwlwifi-kids-audio.conf <<'EOC'
# Optional tweak for Intel wireless adapters.
# This is conservative and may help stability on some systems.
options iwlmvm power_scheme=1
EOC
  log "Installed /etc/modprobe.d/iwlwifi-kids-audio.conf"
fi

# Configure PipeWire Pulse server sample rate.
install -d -o "$TARGET_USER" -g "$TARGET_USER" "$TARGET_HOME/.config/pipewire/pipewire-pulse.conf.d"
cat > "$TARGET_HOME/.config/pipewire/pipewire-pulse.conf.d/10-kids-audio.conf" <<EOC
pulse.properties = {
    server.address = [ "unix:native" ]
    default.clock.rate = $FORCE_SAMPLE_RATE
    default.clock.allowed-rates = [ $FORCE_SAMPLE_RATE 48000 ]
}
EOC
chown "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.config/pipewire/pipewire-pulse.conf.d/10-kids-audio.conf"

# Install helper scripts.
install -d -o "$TARGET_USER" -g "$TARGET_USER" "$TARGET_HOME/bin"

cat > "$TARGET_HOME/bin/kids_audio_reconnect.sh" <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
CONFIG_FILE="$HOME/.config/kids-audio/devices.conf"
INTERVAL="${INTERVAL:-15}"

log() { printf '[kids-audio-reconnect] %s\n' "$*"; }

if [[ ! -f "$CONFIG_FILE" ]]; then
  log "No devices config found at $CONFIG_FILE; exiting."
  exit 0
fi

mapfile -t DEVICES < <(grep -E '^[0-9A-Fa-f:]{17}$' "$CONFIG_FILE" | tr '[:lower:]' '[:upper:]')
[[ ${#DEVICES[@]} -gt 0 ]] || { log "No valid MACs in $CONFIG_FILE"; exit 0; }

bluetoothctl power on >/dev/null 2>&1 || true
bluetoothctl agent on >/dev/null 2>&1 || true
bluetoothctl default-agent >/dev/null 2>&1 || true

while true; do
  for DEV in "${DEVICES[@]}"; do
    bluetoothctl trust "$DEV" >/dev/null 2>&1 || true
    bluetoothctl connect "$DEV" >/dev/null 2>&1 || true
  done
  sleep "$INTERVAL"
done
EOS

cat > "$TARGET_HOME/bin/kids_audio_sink.sh" <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
SINK_NAME="${1:-KidsHub}"
SET_DEFAULT="${2:-1}"

log() { printf '[kids-audio-sink] %s\n' "$*"; }

# Give Bluetooth and PipeWire a moment to settle after boot.
sleep 20

# Wait for PipeWire Pulse to be reachable.
for _ in {1..30}; do
  if pactl info >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

pactl info >/dev/null 2>&1 || { log "pactl not ready"; exit 1; }

# Find currently available Bluetooth sinks.
mapfile -t BT_SINKS < <(pactl list short sinks | awk '/bluez_output/ {print $2}')
if [[ ${#BT_SINKS[@]} -eq 0 ]]; then
  log "No Bluetooth sinks found."
  exit 0
fi

SLAVES=$(IFS=,; echo "${BT_SINKS[*]}")

# Remove any old sink with the same symbolic name.
while read -r line; do
  MOD_ID=$(awk '{print $1}' <<< "$line")
  pactl unload-module "$MOD_ID" >/dev/null 2>&1 || true
done < <(pactl list short modules | grep "module-combine-sink.*sink_name=$SINK_NAME" || true)

MOD_ID=$(pactl load-module module-combine-sink sink_name="$SINK_NAME" slaves="$SLAVES")
log "Loaded module-combine-sink id=$MOD_ID sinks=$SLAVES"

pactl set-sink-volume "$SINK_NAME" 100% >/dev/null 2>&1 || true
if [[ "$SET_DEFAULT" == "1" ]]; then
  pactl set-default-sink "$SINK_NAME" >/dev/null 2>&1 || true
fi
EOS

chmod +x "$TARGET_HOME/bin/kids_audio_reconnect.sh" "$TARGET_HOME/bin/kids_audio_sink.sh"
chown "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/bin/kids_audio_reconnect.sh" "$TARGET_HOME/bin/kids_audio_sink.sh"

# Device config file.
install -d -o "$TARGET_USER" -g "$TARGET_USER" "$TARGET_HOME/.config/kids-audio"
printf '%s\n' "${DEVICE_ARRAY[@]}" > "$TARGET_HOME/.config/kids-audio/devices.conf"
chown "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.config/kids-audio/devices.conf"

# User systemd units.
install -d -o "$TARGET_USER" -g "$TARGET_USER" "$TARGET_HOME/.config/systemd/user"
cat > "$TARGET_HOME/.config/systemd/user/kids-audio-reconnect.service" <<EOS
[Unit]
Description=Kids Audio Bluetooth reconnect loop
After=graphical-session.target pipewire-pulse.service bluetooth.target
Wants=pipewire-pulse.service bluetooth.target

[Service]
Type=simple
ExecStart=%h/bin/kids_audio_reconnect.sh
Restart=always
RestartSec=5
Environment=INTERVAL=15

[Install]
WantedBy=default.target
EOS

cat > "$TARGET_HOME/.config/systemd/user/kids-audio-sink.service" <<EOS
[Unit]
Description=Kids Audio combined sink creator
After=kids-audio-reconnect.service pipewire-pulse.service bluetooth.target
Wants=kids-audio-reconnect.service pipewire-pulse.service bluetooth.target

[Service]
Type=oneshot
ExecStart=%h/bin/kids_audio_sink.sh "$SINK_NAME" "$SET_DEFAULT_SINK"
RemainAfterExit=yes

[Install]
WantedBy=default.target
EOS

chown "$TARGET_USER:$TARGET_USER" \
  "$TARGET_HOME/.config/systemd/user/kids-audio-reconnect.service" \
  "$TARGET_HOME/.config/systemd/user/kids-audio-sink.service"

# Optional YouTube Music desktop app.
if [[ $INSTALL_YTM_DESKTOP -eq 1 ]]; then
  sudo -u "$TARGET_USER" flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true
  sudo -u "$TARGET_USER" flatpak install -y flathub com.github.th_ch.youtube_music || true
fi

# Enable/start user services as target user.
sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/$(id -u "$TARGET_USER")" systemctl --user daemon-reload
sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/$(id -u "$TARGET_USER")" systemctl --user enable kids-audio-reconnect.service kids-audio-sink.service
sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/$(id -u "$TARGET_USER")" systemctl --user restart pipewire pipewire-pulse wireplumber || true
sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/$(id -u "$TARGET_USER")" systemctl --user restart kids-audio-reconnect.service || true
sleep 3
sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/$(id -u "$TARGET_USER")" systemctl --user restart kids-audio-sink.service || true

cat <<EOF2

Setup complete.

What this script did:
  - Installed BlueZ, PipeWire/Pulse, WirePlumber, Flatpak, and tools.
  - Created a Bluetooth reconnect loop service.
  - Created a combined sink service named: $SINK_NAME
  - Wrote headset MACs to: $TARGET_HOME/.config/kids-audio/devices.conf

Useful commands (run as $TARGET_USER):
  systemctl --user status kids-audio-reconnect.service
  systemctl --user status kids-audio-sink.service
  pactl list short sinks
  pactl info | grep 'Default Sink'

If this is the first run:
  1. Pair and trust each headset first if you have not already.
  2. Re-run the script with --devices MAC1,MAC2,MAC3
  3. Reboot if you used --disable-onboard-bt

EOF2
