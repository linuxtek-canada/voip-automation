#!/bin/bash

SINK_NAME="voip_virt"

log() { echo -e "\e[1;32m[INFO]\e[0m $1"; }

# ================= STEP 1: SINK SETUP =================
log "Checking virtual audio sink..."
if ! pactl list sinks short 2>/dev/null | grep -q "$SINK_NAME"; then
    log "Creating virtual sink '$SINK_NAME'..."
    MODULE_ID=$(pactl load-module module-null-sink sink_name="$SINK_NAME" sink_properties=device.description="VoIP_Virtual")
    sleep 1
else
    log "Virtual sink '$SINK_NAME' already exists."
fi

# ================= STEP 2: SOURCE SETUP =================
DEFAULT_SOURCE=$(pactl get-default-source)
log "Setting system input to Monitor of $SINK_NAME..."
pacmd set-default-source ${SINK_NAME}.monitor 2>/dev/null || pactl set-default-source ${SINK_NAME}.monitor

# ================= STEP 3: PAVUCONTROL CHECK =================
echo "--------------------------------------------------------"
echo -e "\e[1;33mACTION REQUIRED:\e[0m"
echo "1. Open pavucontrol."
echo "2. Go to the 'Input Devices' tab."
echo "3. Ensure 'Show' is set to 'All Input Devices' or 'Monitors'."
echo "4. Find the meter for 'Monitor of VoIP_Virtual'."
echo "--------------------------------------------------------"
read -p "Press [Enter] when you are looking at the Input Devices tab..."

# ================= STEP 4: FIRE DTMF =================
log "Firing DTMF sequence with 2-SECOND long tones..."

for digit in "1" "5" "9" "#"; do
    log "Sending tone: $digit"
    
    # Map the exact dual-frequencies for each digit
    case "$digit" in
        "1") F1=697; F2=1209 ;;
        "5") F1=770; F2=1336 ;;
        "9") F1=852; F2=1477 ;;
        "#") F1=941; F2=1477 ;;
    esac

    # Generate both sine waves simultaneously, mix down to 1 channel, pad with silence, and lower gain to prevent clipping
    sox -V0 -n -t raw -r 8000 -c 1 - synth 2.0 sine $F1 sine $F2 channels 1 pad 0 0.5 gain -6 | \
    pacat --device="$SINK_NAME" --rate=8000 --channels=1 --format=s16ne --raw 2>/dev/null
done

log "DTMF sequence complete."

# ================= STEP 5: TEARDOWN =================
log "Restoring default microphone source..."
pacmd set-default-source "$DEFAULT_SOURCE" 2>/dev/null || pactl set-default-source "$DEFAULT_SOURCE"
log "Test finished cleanly."
