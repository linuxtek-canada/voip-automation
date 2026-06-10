#!/usr/bin/env bash

# ================= CONFIGURATION =================
# Load .env if it exists in the script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    set -a
    source "${SCRIPT_DIR}/.env"
    set +a
fi

ZOIPER_CMD="zoiper5"
ZOIPER_PHONE="${ZOIPER_PHONE:-<YOUR_ZOIPER_PHONE_NUMBER>}"
SINK_NAME="${SINK_NAME:-voip_virt}"
# We define the monitor explicitly here to ensure consistent usage
MONITOR_NAME="${SINK_NAME}.monitor"
WAVE_FILE="${ZOIPER_WAVE_FILE:-./audiosamples/sample-speech-30m.wav}"
TOTAL_DURATION="${ZOIPER_TOTAL_DURATION:-1800}"
MPV_VOLUME="${ZOIPER_MPV_VOLUME:-35}"
# =================================================

log() { echo -e "\033[0;32m[$(date '+%H:%M:%S')] $1\033[0m"; }

cleanup() {
    log "Cleaning up and restoring audio..."
    [[ -n "${MPV_PID:-}" ]] && kill "$MPV_PID" 2>/dev/null
    if [[ -n "${DEFAULT_SOURCE:-}" ]]; then
        pactl set-default-source "$DEFAULT_SOURCE" 2>/dev/null
    fi
    exit 0
}
trap cleanup SIGINT SIGTERM EXIT

# ================= STEP 1: SINK & SOURCE SETUP =================
log "Verifying sink: $SINK_NAME"
if ! pactl list sinks short 2>/dev/null | grep -q "$SINK_NAME"; then
    log "Sink not found. Creating $SINK_NAME..."
    pactl load-module module-null-sink sink_name="$SINK_NAME" sink_properties=device.description="VoIP_Virtual"
fi

DEFAULT_SOURCE=$(pactl get-default-source)
log "Routing system input to: $MONITOR_NAME"
pacmd set-default-source "$MONITOR_NAME" 2>/dev/null || pactl set-default-source "$MONITOR_NAME"

# ================= STEP 2: DTMF ENGINE =================

play_digit() {
    local digit="$1"
    # Standard Frequencies
    case "$digit" in
        "1") F1=697; F2=1209 ;; "2") F1=697; F2=1336 ;; "3") F1=697; F2=1477 ;;
        "4") F1=770; F2=1209 ;; "5") F1=770; F2=1336 ;; "6") F1=770; F2=1477 ;;
        "7") F1=852; F2=1209 ;; "8") F1=852; F2=1336 ;; "9") F1=852; F2=1477 ;;
        "0") F1=941; F2=1336 ;; "*") F1=941; F2=1209 ;; "#") F1=941; F2=1477 ;;
    esac
    
    # We use a 0.5s clean tone. 
    # RFC 2833 detection is very fast; 0.5s is perfect for Zoiper to lock on.
    sox -V0 -n -r 8000 -c 1 - synth 0.5 sine $F1 sine $F2 gain -3 \
    -t ul - | \
    pacat --device="$SINK_NAME" --rate=8000 --channels=1 --format=ulaw --raw 2>/dev/null
}

# ================= STEP 3: EXECUTION =================
log "Initiating Zoiper call..."
# &> redirects both stdout and stderr to /dev/null for the command and all child processes
"$ZOIPER_CMD" --dial="$ZOIPER_PHONE" &>/dev/null &
ZOIPER_PID=$!

read -n1 -p "Zoiper is dialing. Press any key ONCE the IVR is active..."
echo ""

log "Warming up stream..."
log "Starting background audio via $SINK_NAME..."
mpv --no-video --loop --audio-device="pulse/$SINK_NAME" --volume="$MPV_VOLUME" "$WAVE_FILE" &
MPV_PID=$!

log "IVR automation running for 30 minutes..."
sleep "$TOTAL_DURATION"
