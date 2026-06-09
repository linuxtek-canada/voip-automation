#!/usr/bin/env bash

# ================= CONFIGURATION =================
SCRIPT_NAME="linphone_call_test"
LINPHONEC_CMD="linphonec"
LINPHONEC_SH="linphonecsh"
DEST_PHONE="${DEST_PHONE:-<YOUR_PHONE_NUMBER>}"
SINK_NAME="voip_virt"
MONITOR_NAME="${SINK_NAME}.monitor"
VOIP_8K_SINK="voip_virt_8k"
VOIP_8K_MONITOR="${VOIP_8K_SINK}.monitor"
WAVE_FILE="audiosamples/sample-speech-30m.wav"
TEST_CALL_WAVE="audiosamples/wopr_strangegame.wav"
DEFAULT_LOG_LEVEL=3
DEFAULT_TEST_DURATION=1800
MPV_VOLUME=100

# Runtime variables
LOG_FILE=""
DEBUG_LEVEL=3
TAIL_LOGS=false
CHECK_REG=false
TEST_CALL=false
IVR_TEST=false
AUDIO_TEST=false
SINK_TEST=false
IVR_DURATION=""
LINPHONEC_PID=""
DEFAULT_SOURCE=""
DEFAULT_SINK=""
MPV_PID=""
LINPHONERC_FILE=""
ECHO_CANCEL_MODULE=""

# Proxy config
PROXY_HOST="${VOIP_PROXY_HOST:-<YOUR_VOIP_PROXY_HOST>}"
USERNAME="${VOIP_USERNAME:-<YOUR_VOIP_USERNAME>}"
PASSWORD="${VOIP_PASSWORD:-<YOUR_VOIP_PASSWORD>}"
IDENTITY="${VOIP_IDENTITY:-sip:<YOUR_VOIP_USERNAME>@<YOUR_VOIP_PROXY_HOST>}"

# =================================================
# ================= UTILITY FUNCTIONS =============
# =================================================

log() {
    local msg="[$(date '+%H:%M:%S')] $1"
    printf '\033[0;32m%s\033[0m\n' "$msg"
    if [[ -n "${LOG_FILE:-}" ]]; then
        printf '%s\n' "${msg}" >> "$LOG_FILE"
    fi
}

log_error() {
    echo -e "\033[0;31m[$(date '+%H:%M:%S')] ERROR: $1\033[0m" >&2
    if [[ -n "${LOG_FILE:-}" ]]; then
        echo -e "[$(date '+%H:%M:%S')] ERROR: $1" >> "$LOG_FILE"
    fi
}

usage() {
    cat <<USAGE_EOF
Usage: $SCRIPT_NAME.sh [OPTIONS] <MODE>

Modes:
  --check-reg              Check SIP registration status and exit
  --test-call              Make a short test call to default DEST_PHONE or --phone value
  --ivr-test [seconds]     Run IVR automation (default: ${DEFAULT_TEST_DURATION}s)
  --audio-test             Play test audio through default system speaker (no call needed)
  --sink-test              Play test audio to virtual sink (voip_virt) for device monitoring

Options:
  --log-file <path>        Path to log file (default: /tmp/linphone-call-test-<timestamp>.log)
  --debug-level <0-6>      Linphone verbose level (default: ${DEFAULT_LOG_LEVEL})
  --tail-logs              Tail log file after script completes
  --phone <number>         Override destination phone number (default: $DEST_PHONE)
  --help                   Show this help message

Examples:
  $SCRIPT_NAME.sh --check-reg
  $SCRIPT_NAME.sh --test-call --debug-level 5
  $SCRIPT_NAME.sh --ivr-test 300 --tail-logs
  $SCRIPT_NAME.sh --audio-test
  $SCRIPT_NAME.sh --sink-test
USAGE_EOF
}

cleanup() {
    local exit_code=$?
    log "Cleaning up..."

    if [[ -n "${MPV_PID:-}" ]]; then
        log "Stopping mpv (PID: $MPV_PID)..."
        kill "$MPV_PID" 2>/dev/null || true
        wait "$MPV_PID" 2>/dev/null || true
        MPV_PID=""
    fi

    log "Stopping linphonec daemon..."
    "$LINPHONEC_SH" exit 2>/dev/null || true
    sleep 2

    if [[ -n "${DEFAULT_SOURCE:-}" ]]; then
        log "Restoring default audio source: $DEFAULT_SOURCE"
        pactl set-default-source "$DEFAULT_SOURCE" 2>/dev/null || true
    fi

    if [[ -n "${ECHO_CANCEL_MODULE:-}" && "$ECHO_CANCEL_MODULE" != "0" ]]; then
        log "Removing echo cancellation module ($ECHO_CANCEL_MODULE)..."
        pactl unload-module "$ECHO_CANCEL_MODULE" 2>/dev/null || true
    fi

    if [[ -n "${LINPHONERC_FILE:-}" && -f "${LINPHONERC_FILE:-}" ]]; then
        rm -f "$LINPHONERC_FILE"
        log "Removed temporary linphonerc: $LINPHONERC_FILE"
    fi

    if [[ $exit_code -ne 0 ]]; then
        log_error "Script exited with code $exit_code"
    fi

    if [[ "$TAIL_LOGS" == true && -f "${LOG_FILE:-}" ]]; then
        log "=== Last 50 lines of log file: $LOG_FILE ==="
        tail -50 "$LOG_FILE" 2>/dev/null || true
    fi

    exit $exit_code
}

# ================= AUDIO SETUP ===================

setup_audio() {
    log "Verifying virtual audio sink: $SINK_NAME"

    if ! pactl list sinks short 2>/dev/null | grep -q "$SINK_NAME"; then
        log "Creating virtual sink '$SINK_NAME'..."
        pactl load-module module-null-sink sink_name="$SINK_NAME" sink_properties=device.description="VoIP_Virtual" 2>/dev/null
        sleep 1
    else
        log "Virtual sink '$SINK_NAME' already exists."
    fi

    DEFAULT_SOURCE=$(pactl get-default-source)
    DEFAULT_SINK=$(pactl get-default-sink)
    log "Routing system input to monitor: $MONITOR_NAME"
   pacmd set-default-source "$MONITOR_NAME" 2>/dev/null || pactl set-default-source "$MONITOR_NAME"

    SINK_DESCRIPTION=$(pactl list sinks short 2>/dev/null | grep "$SINK_NAME" | awk '{print $NF}')
    if [[ -z "$SINK_DESCRIPTION" ]]; then
        SINK_DESCRIPTION="VoIP_Virtual"
    fi
    log "Detected sink description: $SINK_DESCRIPTION"
}

# ================= DTMF ENGINE ===================

play_digit() {
    local digit="$1"
    local duration="${2:-0.5}"

    case "$digit" in
        "1") F1=697; F2=1209 ;; "2") F1=697; F2=1336 ;; "3") F1=697; F2=1477 ;;
        "4") F1=770; F2=1209 ;; "5") F1=770; F2=1336 ;; "6") F1=770; F2=1477 ;;
        "7") F1=852; F2=1209 ;; "8") F1=852; F2=1336 ;; "9") F1=852; F2=1477 ;;
        "0") F1=941; F2=1336 ;; "*") F1=941; F2=1209 ;; "#") F1=941; F2=1477 ;;
    esac

    sox -V0 -n -r 48000 -c 2 - synth "$duration" sine "$F1" sine "$F2" gain -3 \
        -t raw -e signed-integer -b 16 - | \
        pacat --device="$SINK_NAME" --rate=48000 --channels=2 --format=s16le 2>/dev/null || true
}

play_sequence() {
    local sequence="$1"
    local gap="${2:-0.1}"

    for (( i=0; i<${#sequence}; i++ )); do
        play_digit "${sequence:$i:1}"
        if [[ $i -lt $((${#sequence}-1)) ]]; then
            sleep "$gap"
        fi
    done
}

# ================= LINPHONERC SETUP ==============

generate_linphonerc() {
    LINPHONERC_FILE=$(mktemp /tmp/linphone-XXXXXX.conf)

    mkdir -p "${HOME}/.local/share/linphone" 2>/dev/null || true

    local default_sink_name
    default_sink_name=$(pactl get-default-sink)
    log "Default system sink: $default_sink_name"
    log "Capture device: ${MONITOR_NAME}"

    cat > "$LINPHONERC_FILE" <<LINPHONERC_EOF
[logging]
log_file_enabled=true
log_file=${LOG_FILE}
log_level=${DEBUG_LEVEL}
log_to_syslog=false

[sip]
transport=tls
port=5061
nat_behavior=force_rport
ice_enabled=true
root_ca=/usr/share/linphone/linphone/rootca.pem
verify_server_certs=1
verify_server_cn=0
auto_send_ringing=1
media_encryption=srtp
supported=replaces, outbound, gruu, path
user_agent=Linphonec/5.2.0

[tls]
ca_list=/etc/ssl/certs/ca-certificates.crt
verify_server=true
verify_client=false

[proxy]
identity=${IDENTITY}
proxy=${PROXY_HOST}
reg_expires=3600

[media]
media_encryption=srtp
ice_enabled=true
audio_codecs_enabled=G722,PCMU,PCMA
audio_jitter_enabled=true
dtmf_send_mode=info
echo_canceller_enabled=true
echo_canceller_tail=512

[sound]
capture_dev_id=${MONITOR_NAME}
playback_dev_id=${SINK_NAME}
ringer_dev_id=${default_sink_name}

[auth_info]
username=${USERNAME}
password=${PASSWORD}
realm=${PROXY_HOST}

[net]
nat_policy_ref=_auto

[nat_policy_0]
ref=_auto

[app]
auto_download_incoming_files_max_size=-1
auto_download_incoming_voice_recordings=1
auto_download_incoming_icalendars=1
sender_name_hidden_in_forward_message=0
record_aware=0

[misc]
user_certificates_path=${HOME}/.linphone-usr-crt
LINPHONERC_EOF

    log "Generated linphonerc at: $LINPHONERC_FILE"
}

# ================= LINPHONEC MANAGEMENT =========

start_linphonec() {
    log "Starting linphonec daemon..."
    log "Config: $LINPHONERC_FILE | Debug: $DEBUG_LEVEL"

    log "Stopping any existing linphonec processes..."
    "$LINPHONEC_SH" exit 2>/dev/null || true
    sleep 2
    kill $(pgrep -f "linphonec --pipe") 2>/dev/null || true
    sleep 2
    kill -9 $(pgrep -f "linphonec --pipe") 2>/dev/null || true
    sleep 2

    nohup "$LINPHONEC_SH" init -c "$LINPHONERC_FILE" -d "$DEBUG_LEVEL" >> "$LOG_FILE" 2>&1 &
    local init_pid=$!
    disown "$init_pid" 2>/dev/null || true

    sleep 4

    LINPHONEC_PID=$(pgrep -f "linphonec --pipe" | head -1)

    if [[ -z "$LINPHONEC_PID" ]]; then
        log_error "linphonec daemon failed to start. Check logs at: $LOG_FILE"
        return 1
    fi

    log "linphonec daemon running (PID: $LINPHONEC_PID)"
    do_registration
    return 0
}

do_registration() {
    log "Registering with SIP server..."
    "$LINPHONEC_SH" register --host "$PROXY_HOST" --username "$USERNAME" --password "$PASSWORD" 2>/dev/null
    sleep 2
    return 0
}

stop_linphonec() {
    log "Stopping linphonec daemon..."
    "$LINPHONEC_SH" exit 2>/dev/null || true
    sleep 2
    LINPHONEC_PID=""
    log "linphonec daemon stopped."
}

wait_for_registration() {
    local max_attempts="${1:-30}"
    local interval="${2:-2}"
    local attempt=0
    local status=""

    log "Waiting for SIP registration (max ${max_attempts} attempts, ${interval}s interval)..."

    while [[ $attempt -lt $max_attempts ]]; do
        sleep "$interval"
        attempt=$((attempt + 1))

        status=$("$LINPHONEC_SH" status register 2>/dev/null) || true
        log "Registration check $attempt/$max_attempts: $status"

        if echo "$status" | grep -qi "registered"; then
            log "Successfully registered with SIP server!"
            return 0
        fi

        if [[ $attempt -lt $max_attempts ]]; then
            log "Still waiting for registration..."
        fi
    done

    log_error "Registration timeout after ${max_attempts} attempts"
    log_error "Last status output: $status"
    return 1
}

wait_for_call_connected() {
    local max_attempts="${1:-30}"
    local interval="${2:-2}"
    local attempt=0
    local call_status=""

    log "Waiting for call to connect (max ${max_attempts} attempts, ${interval}s interval)..."

    while [[ $attempt -lt $max_attempts ]]; do
        sleep "$interval"
        attempt=$((attempt + 1))

        call_status=$("$LINPHONEC_SH" generic "calls" 2>/dev/null) || true
        log "Call check $attempt/$max_attempts: $call_status"

        if echo "$call_status" | grep -qi "StreamsRunning"; then
            log "Call is connected - streams running!"
            return 0
        fi

        if [[ $attempt -lt $max_attempts ]]; then
            log "Still waiting for call to connect..."
        fi
    done

    log_error "Call connection timeout after ${max_attempts} attempts"
    log_error "Last call status: $call_status"
    return 1
}

# ================= MODE: CHECK REGISTRATION ======

mode_check_reg() {
    log "============================================="
    log "SIP Registration Check Mode"
    log "============================================="

    generate_linphonerc
    if ! start_linphonec; then
        return 1
    fi

    if ! wait_for_registration 15 2; then
        log_error "Registration check failed. Full logs at: $LOG_FILE"
        log_error "Tip: Re-run with --debug-level 5 for more details"
        return 1
    fi

    log "============================================="
    log "Registration Status: SUCCESS"
    log "============================================="
    return 0
}

# ================= MODE: TEST CALL ===============

mode_test_call() {
    local phone="${1:-$DEST_PHONE}"
    log "============================================="
    log "Short Test Call Mode"
    log "Destination: $phone"
    log "============================================="

    generate_linphonerc
    if ! start_linphonec; then
        return 1
    fi

    if ! wait_for_registration 15 2; then
        log_error "Registration failed. Cannot place test call."
        log_error "Full logs at: $LOG_FILE"
        return 1
    fi

    log "Dialing $phone..."
    "$LINPHONEC_SH" dial "$phone"

    if wait_for_call_connected 30 2; then
        log "Call connected successfully!"
    else
        log "Call may not be connected. Proceeding with timeout..."
    fi

    local call_status
    call_status=$("$LINPHONEC_SH" generic "calls" 2>/dev/null) || true
    log "Call state: $call_status"

    local pa_info
    pa_info=$(pactl list sinks short 2>/dev/null | grep "$SINK_NAME" || true)
    log "PulseAudio sink status: $pa_info"
    pa_monitor_info=$(pactl list sinks short 2>/dev/null | grep "$MONITOR_NAME" || true)
    log "PulseAudio monitor status: $pa_monitor_info"

    if [[ -f "$TEST_CALL_WAVE" ]]; then
        log "Waiting for audio pipeline to be ready..."
        sleep 3
        log "Pre-warming AEC with 2s silence on $SINK_NAME..."
        sox -V0 -n -r 48000 -c 2 -t raw -e signed-integer -b 16 - synth 2.0 sine 0 \
            | pacat --raw --device="$SINK_NAME" --rate=48000 --channels=2 --format=s16le 2>/dev/null
        log "AEC warmed. Playing test audio: $TEST_CALL_WAVE to $SINK_NAME"
        sox -V0 "$TEST_CALL_WAVE" -t raw -r 48000 -c 2 -e signed-integer -b 16 - vol 1.5 \
            | pacat --raw --device="$SINK_NAME" --rate=48000 --channels=2 --format=s16le 2>/dev/null &
        MPV_PID=$!
        log "sox+pacat playing: $TEST_CALL_WAVE (PID: $MPV_PID)"
        sleep 3
        log "sox+pacat active - linphone should be capturing from $MONITOR_NAME"
        pactl list sources short 2>/dev/null | grep -i monitor
        pactl list sinks short 2>/dev/null | grep -A5 "$SINK_NAME" | head -10
        wait "$MPV_PID" 2>/dev/null || true
        MPV_PID=""
        log "Audio playback complete"
        sleep 1
    else
        log "Warning: Test WAV not found: $TEST_CALL_WAVE"
        sleep 5
    fi

    log "Ending call..."
    "$LINPHONEC_SH" generic "terminate" 2>/dev/null || true
    sleep 2

    log "============================================="
    log "Test call completed"
    log "Full logs at: $LOG_FILE"
    log "============================================="
    return 0
}

# ================= MODE: AUDIO TEST ================

mode_audio_test() {
    log "============================================="
    log "Audio Diagnostic Test Mode"
    log "============================================="

    local default_sink
    default_sink=$(pactl get-default-sink)
    log "Default system sink: $default_sink"

    local sink_info
    sink_info=$(pactl list sinks short 2>/dev/null | grep "$(pactl get-default-sink | awk '{print $1}')" || true)
    log "Sink details: $sink_info"

    if [[ ! -f "$TEST_CALL_WAVE" ]]; then
        log_error "Test WAV not found: $TEST_CALL_WAVE"
        log_error "Please ensure the file exists and is accessible."
        return 1
    fi

    local wave_info
    wave_info=$(ffprobe -v error -show_entries format=name,format_long_name,sample_rate,channels,duration -of default=noprint_wrappers=1 "$TEST_CALL_WAVE" 2>&1) || true
    log "Audio file info:"
    echo "$wave_info" | while IFS= read -r line; do
        log "  $line"
    done

    log "============================================="
    log "Playing: $TEST_CALL_WAVE"
    log "Output device: $default_sink"
    log "Volume: $MPV_VOLUME"
    log "============================================="
    log "Press Ctrl+C to stop early"
    log ""

    mpv --no-video --audio-device="pulse/$default_sink" --volume="$MPV_VOLUME" "$TEST_CALL_WAVE"
    local mpv_exit=$?

    if [[ $mpv_exit -eq 0 ]]; then
        log ""
        log "Playback complete. If you heard the audio, the output device is working."
    else
        log_error "mpv exited with code $mpv_exit"
    fi

    log ""
    log "============================================="
    log "Audio diagnostic completed"
    log "============================================="
    return $mpv_exit
}

# ================= MODE: SINK TEST =================

mode_sink_test() {
    log "============================================="
    log "Sink Audio Test Mode"
    log "Sink: $SINK_NAME | Monitor: $MONITOR_NAME"
    log "============================================="

    if [[ ! -f "$TEST_CALL_WAVE" ]]; then
        log_error "Test WAV not found: $TEST_CALL_WAVE"
        log_error "Please ensure the file exists and is accessible."
        return 1
    fi

    local wave_info
    wave_info=$(ffprobe -v error -show_entries format=name,format_long_name,sample_rate,channels,duration -of default=noprint_wrappers=1 "$TEST_CALL_WAVE" 2>&1) || true
    log "Audio file info:"
    echo "$wave_info" | while IFS= read -r line; do
        log "  $line"
    done

    log "============================================="
    log "Playing: $TEST_CALL_WAVE"
    log "Output device: $SINK_NAME"
    log "Volume: $MPV_VOLUME"
    log "============================================="
    log "Press Ctrl+C to stop early"
    log ""

    mpv --no-video --audio-device="pulse/$SINK_NAME" --volume="$MPV_VOLUME" "$TEST_CALL_WAVE"
    local mpv_exit=$?

    if [[ $mpv_exit -eq 0 ]]; then
        log ""
        log "Playback complete. Check your audio device monitoring tools for activity on $SINK_NAME / $MONITOR_NAME."
    else
        log_error "mpv exited with code $mpv_exit"
    fi

    log ""
    log "============================================="
    log "Sink test completed"
    log "============================================="
    return $mpv_exit
}

# ================= MODE: IVR TEST =================

mode_ivr_test() {
    local duration="${1:-$DEFAULT_TEST_DURATION}"
    local phone="${2:-$DEST_PHONE}"

    log "============================================="
    log "IVR Automation Test Mode"
    log "Destination: $phone"
    log "Duration: ${duration}s"
    log "============================================="

    generate_linphonerc
    if ! start_linphonec; then
        return 1
    fi

    if ! wait_for_registration 15 2; then
        log_error "Registration failed. Cannot place IVR test call."
        log_error "Full logs at: $LOG_FILE"
        return 1
    fi

    log "Dialing $phone..."
    "$LINPHONEC_SH" dial "$phone"

    if wait_for_call_connected 60 2; then
        log "Call connected, IVR should be active!"
    else
        log "Call may not be connected. Proceeding with timeout..."
    fi

    local pa_info
    pa_info=$(pactl list sinks short 2>/dev/null | grep "$SINK_NAME" || true)
    log "PulseAudio sink status: $pa_info"
    pa_monitor_info=$(pactl list sinks short 2>/dev/null | grep "$MONITOR_NAME" || true)
    log "PulseAudio monitor status: $pa_monitor_info"

    log "Warming up stream..."
    play_digit "1"
    sleep 1

    play_sequence "30416473#"
    log "Pause: 5s"
    sleep 5

    play_sequence "123123#"
    log "Pause: 5s"
    sleep 5

    log "Verifying call is still connected..."
    local call_state
    call_state=$("$LINPHONEC_SH" generic "calls" 2>/dev/null) || true
    log "Call state check: $call_state"

    log "Waiting for audio pipeline to be ready..."
    sleep 5

    log "Starting background audio via $SINK_NAME..."
    if [[ -f "$WAVE_FILE" ]]; then
        sox -V0 "$WAVE_FILE" -t raw -r 48000 -c 2 -e signed-integer -b 16 - vol 1.5 \
            | pacat --raw --device="$SINK_NAME" --rate=48000 --channels=2 --format=s16le --loop=0 2>/dev/null &
        MPV_PID=$!
        log "sox+pacat looping: $WAVE_FILE (PID: $MPV_PID) to $SINK_NAME"
        sleep 3
        log "sox+pacat should now be active on $SINK_NAME - linphone should be capturing from ${SINK_NAME}.monitor"
        pactl list sources short 2>/dev/null | grep -i monitor
        pactl list sinks short 2>/dev/null | grep -A5 "$SINK_NAME" | head -10
    else
        log_error "WAV file not found: $WAVE_FILE"
        log_error "Using silent background (no audio playback)"
    fi

    log "IVR automation running for ${duration}s..."

    local remaining=$duration
    while [[ $remaining -gt 0 ]]; do
        sleep 60
        remaining=$((remaining - 60))
        log "Remaining: ${remaining}s"

        if [[ $remaining -le 0 ]]; then
            break
        fi

        log "Playing periodic DTMF sequence..."
        play_sequence "1234567890*#"
        sleep 3
    done

    log "IVR test duration complete."
    log "Ending call..."
    "$LINPHONEC_SH" generic "terminate" 2>/dev/null || true
    sleep 2

    log "============================================="
    log "IVR test completed"
    log "Full logs at: $LOG_FILE"
    log "============================================="
    return 0
}

# ================= MAIN ==========================

main() {
    if [[ $# -eq 0 ]]; then
        usage
        exit 1
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --check-reg)
                CHECK_REG=true
                shift
                ;;
            --test-call)
                TEST_CALL=true
                shift
                ;;
            --ivr-test)
                IVR_TEST=true
                shift
                if [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]]; then
                    IVR_DURATION="$1"
                    shift
                fi
                ;;
            --log-file)
                LOG_FILE="$2"
                shift 2
                ;;
            --debug-level)
                DEBUG_LEVEL="$2"
                shift 2
                ;;
            --tail-logs)
                TAIL_LOGS=true
                shift
                ;;
            --phone)
                DEST_PHONE="$2"
                shift 2
                ;;
            --audio-test)
                AUDIO_TEST=true
                shift
                ;;
            --sink-test)
                SINK_TEST=true
                shift
                ;;
            --help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    local reg_val=0 test_val=0 ivr_val=0 audio_val=0 sink_val=0
    [[ "$CHECK_REG" == true ]] && reg_val=1
    [[ "$TEST_CALL" == true ]] && test_val=1
    [[ "$IVR_TEST" == true ]] && ivr_val=1
    [[ "$AUDIO_TEST" == true ]] && audio_val=1
    [[ "$SINK_TEST" == true ]] && sink_val=1
    local mode_count=$(( reg_val + test_val + ivr_val + audio_val + sink_val ))
    if [[ $mode_count -eq 0 ]]; then
        log_error "No mode specified. Use --check-reg, --test-call, --ivr-test, --audio-test, or --sink-test"
        usage
        exit 1
    fi

    if [[ $mode_count -gt 1 ]]; then
        log_error "Multiple modes specified. Only one mode allowed."
        exit 1
    fi

    if [[ -z "${LOG_FILE:-}" ]]; then
        local timestamp
        timestamp=$(date '+%Y%m%d-%H%M%S')
        LOG_FILE="/tmp/linphone-call-test-${timestamp}.log"
    fi

    mkdir -p "$(dirname "$LOG_FILE")"

    log "============================================="
    log "${SCRIPT_NAME}"
    log "Log file: $LOG_FILE"
    log "============================================="

    trap cleanup SIGINT SIGTERM EXIT

    if [[ "$AUDIO_TEST" == false ]]; then
        setup_audio
    fi

    local exit_code=0
    if [[ "$CHECK_REG" == true ]]; then
        mode_check_reg
        exit_code=$?
    elif [[ "$TEST_CALL" == true ]]; then
        mode_test_call "$DEST_PHONE"
        exit_code=$?
    elif [[ "$IVR_TEST" == true ]]; then
        mode_ivr_test "${IVR_DURATION:-$DEFAULT_TEST_DURATION}" "$DEST_PHONE"
        exit_code=$?
    elif [[ "$AUDIO_TEST" == true ]]; then
        mode_audio_test
        exit_code=$?
    elif [[ "$SINK_TEST" == true ]]; then
        mode_sink_test
        exit_code=$?
    fi

    exit ${exit_code:-0}
}

main "$@"
