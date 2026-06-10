# VoIP Automation

SIP/IVR testing and automation scripts for VoIP systems. Supports Linphone and Zoiper SIP clients.

## Prerequisites

- **Linux** (PulseAudio-based audio system)
- **Linphone** (`linphonec`, `linphonecsh`) or **Zoiper 5** (`zoiper5`)
- **PulseAudio** (`pactl`, `pacmd`)
- **SOX** (`sox`) - for DTMF tone generation
- **MPV** (`mpv`) - for audio playback diagnostics
- **FFprobe** (`ffprobe`) - for audio file inspection

Install dependencies (Debian/Ubuntu):

```bash
sudo apt install sox libsox-fmt-all mpv ffprobe linphone zoiper5 pulseaudio-utils
```

## Configuration

All credentials and phone numbers must be set before running. You can use a `.env` file or set environment variables directly.

### Environment Variables

A `.env.example` file is provided with all required placeholders. Copy it and fill in your values:

```bash
cp .env.example .env
```

Load the variables before running any script:

```bash
source .env
```

| Variable | Script | Purpose |
|---|---|---|
| `DEST_PHONE` | `linphone_call_test.sh` | Destination phone number for calls |
| `VOIP_PROXY_HOST` | `linphone_call_test.sh` | SIP server address |
| `VOIP_USERNAME` | `linphone_call_test.sh` | SIP username |
| `VOIP_PASSWORD` | `linphone_call_test.sh` | SIP password |
| `VOIP_IDENTITY` | `linphone_call_test.sh` | Full SIP identity (optional, auto-built) |
| `ZOIPER_PHONE` | `zoiper_call_test.sh` | Destination phone number for Zoiper calls |
| `ZOIPER_WAVE_FILE` | `zoiper_call_test.sh` | Path to test audio file |

Alternatively, you can edit the default values directly in the scripts.

### VoIP Account Settings

The following variables are defined at the top of each script. Replace the placeholders with your actual values:

**linphone_call_test.sh:**
```bash
DEST_PHONE="${DEST_PHONE:-<YOUR_PHONE_NUMBER>}"
VOIP_PROXY_HOST="${VOIP_PROXY_HOST:-<YOUR_VOIP_PROXY_HOST>}"
VOIP_USERNAME="${VOIP_USERNAME:-<YOUR_VOIP_USERNAME>}"
VOIP_PASSWORD="${VOIP_PASSWORD:-<YOUR_VOIP_PASSWORD>}"
VOIP_IDENTITY="${VOIP_IDENTITY:-sip:<YOUR_VOIP_USERNAME>@<YOUR_VOIP_PROXY_HOST>}"
```

**zoiper_call_test.sh:**
```bash
ZOIPER_PHONE="${ZOIPER_PHONE:-<YOUR_ZOIPER_PHONE_NUMBER>}"
ZOIPER_WAVE_FILE="${ZOIPER_WAVE_FILE:-./audiosamples/sample-speech-30m.wav}"
```

### Audio Files

You will need to provide your own test audio files in the `audiosamples/` directory. The scripts expect `.wav` files.

**Recommended sources for free audio samples:**

- **[FreeSound](https://freesound.org)** — Search for "speech" or "voice" and filter by Creative Commons licenses
- **[VoxServ Audio Quality Testing Samples](https://github.com/voxserv/audio_quality_testing_samples)** — Ready-made speech samples for VoIP quality testing
- **[VoIP Troubleshooter Open Speech Corpus](https://www.voiptroubleshooter.com/open_speech)** — English speech samples in multiple formats (WAV, AU, FLAC)

**Recommended format for VoIP use (G.711, SOX, MPV):**

**Recommended format for VoIP use (G.711, SOX, MPV):**

| Property | Value |
|----------|-------|
| Format | WAV (PCM) |
| Sample rate | 8000 Hz (8 kHz) |
| Channels | 1 (mono) |
| Sample format | 16-bit signed integer (S16LE) |
| Bit depth | 16 bits |
| Byte order | Little-endian |

G.711 codecs used by SIP/VoIP systems expect 8 kHz mono audio. Using other sample rates or channel counts may cause playback issues, speed distortion, or one-way audio. SOX and MPV handle these formats natively.

**Converting audio files to the recommended format with ffmpeg:**

```bash
# MP3 (or any format) → G.711-compatible WAV (8kHz, mono, 16-bit PCM)
ffmpeg -i input.mp3 -ar 8000 -ac 1 -sample_fmt s16 -c:a pcm_s16le output.wav

# MP3 → 8kHz mono WAV (shorter form)
ffmpeg -i input.mp3 -ar 8000 -ac 1 output.wav

# Convert existing multi-channel or different sample rate WAV
ffmpeg -i input.wav -ar 8000 -ac 1 -sample_fmt s16 -c:a pcm_s16le output.wav

# MP3 → A-law WAV (G.711 A-law format for some VoIP systems)
ffmpeg -i input.mp3 -ar 8000 -ac 1 -c:a pcm_alaw output_alaw.wav

# MP3 → μ-law WAV (G.711 μ-law format, common in North America)
ffmpeg -i input.mp3 -ar 8000 -ac 1 -c:a pcm_ulaw output_ulaw.wav
```

**Inspecting audio files:**

```bash
# Check current format of an audio file
ffprobe -v quiet -print_format json -show_streams input.wav

# Quick summary
ffprobe -v quiet -show_entries stream=sample_rate,channels,codec_name,bits_per_sample -of default=noprint_wrappers=1 input.wav

# Verify with sox
sox --info input.wav
```

### Linphone Configuration

A sample Linphone configuration file is provided at `.linphonerc.example`. The `linphone_call_test.sh` script generates this dynamically, but you can use this file as a reference for manually configuring Linphone.

## Usage

### linphone_call_test.sh

The main automation script with multiple modes.

```bash
chmod +x linphone_call_test.sh
```

**Modes:**

| Mode | Flag | Description |
|------|------|-------------|
| Check Registration | `--check-reg` | Verify SIP registration status |
| Test Call | `--test-call` | Place a short test call with audio playback |
| IVR Automation | `--ivr-test [seconds]` | Run full IVR test with DTMF sequences and audio (default: 1800s) |
| Audio Diagnostic | `--audio-test` | Play test audio through system speakers |
| Sink Test | `--sink-test` | Play test audio to virtual sink for monitoring |

**Options:**

| Option | Description |
|--------|-------------|
| `--log-file <path>` | Custom log file path |
| `--debug-level <0-6>` | Linphone log verbosity (default: 3) |
| `--tail-logs` | Show last 50 log lines on exit |
| `--phone <number>` | Override destination phone number |

**Examples:**

```bash
# Check SIP registration
./linphone_call_test.sh --check-reg

# Place a 30-second test call
./linphone_call_test.sh --test-call

# Run IVR automation for 10 minutes with verbose logging
./linphone_call_test.sh --ivr-test 600 --debug-level 5 --tail-logs

# Play audio through system speakers (no call needed)
./linphone_call_test.sh --audio-test

# Play audio to virtual sink for device monitoring
./linphone_call_test.sh --sink-test
```

### zoiper_call_test.sh

Simpler Zoiper-based IVR testing script.

```bash
chmod +x zoiper_call_test.sh
./zoiper_call_test.sh
```

Runs a 30-minute IVR test with DTMF sequences and background audio playback through Zoiper.

Once the call is established, manually enter any DTMF prompts through Zoiper. We had tried to simulate this, but some phone systems would not recognize it.

In the script, you will see "Zoiper is dialing. Press any key ONCE the IVR is active...". Once you are past the IVR prompts, press any button, and the audio clip will start playing, looped for 30 minutes.

Alternatively, you can manually play audio through the virtual sink using the following command line tool:

```
mpv --no-video --loop --audio-device=pulse/voip_virt --af="pan=mono,aresample=8000,volume=+2dB" ~/audiosamples/sample-speech-30m.mp3
```

### dtmf_test.sh

Standalone DTMF tone generator. Sends a DTMF sequence (`1-5-9-#`) through a virtual audio sink for testing tone detection.

```bash
chmod +x dtmf_test.sh
./dtmf_test.sh
```
Will prompt you to open `pavucontrol` and verify the virtual sink monitor input device.
Note that many phone systems will not recognize simulated DTMF tones, whether in-band or RFC2833 via this method.

## Architecture

```
voip-automation/
├── linphone_call_test.sh   # Main script - Linphone IVR automation
├── zoiper_call_test.sh     # Alternative script - Zoiper IVR automation
├── dtmf_test.sh            # Standalone DTMF tone generator
├── .linphonerc.example     # Reference Linphone configuration
├── audiosamples/           # Test audio files (wav/mp3)
├── .gitignore
└── README.md
```

The scripts use PulseAudio's virtual sink mechanism (`voip_virt`) to route audio from VoIP calls to a monitor source, allowing system audio to be captured by the SIP client. DTMF tones are generated using SOX and played through the virtual sink.
