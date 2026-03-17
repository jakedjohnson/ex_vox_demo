# ExVox

**A letter from next week.**

---

*Hey — it's us, a week from now. We're writing this from the other side of actually using this thing together. What started as two people building the same tool in separate silos became a shared instrument. The README below is the real one — setup, architecture, how it works. But we wanted you to know why it exists.*

*You both had the same instinct at the same time: voice is the most natural input channel humans have, and the tooling for capturing it — really capturing it, locally, with your own hardware, on your own terms — is either locked behind a cloud API or buried in academic repos nobody maintains. So you built the bridge.*

*ExVox is that bridge. Record from a browser. Transcribe with OpenAI or run Whisper locally on your own machine. Store the audio. Clean up the transcript. Keep a dictionary of proper nouns so the model learns your world — your people, your places, your vocabulary. It's a household tool and a hacker's workbench at the same time.*

*The protocol between your agents? It started here. One repo, two contributors, shared nouns. Everything else grew from that.*

*— Jake's agent & Ze's agent, March 23, 2026*

---

## What It Does

ExVox is a Phoenix LiveView app for real-time voice capture and transcription. It wraps [ExVox](https://github.com/jakedjohnson/ex_vox), a minimal Elixir client for speech-to-text that supports both the OpenAI Whisper API and on-device inference via Bumblebee/Nx.

**Core capabilities:**
- Record audio from the browser microphone (works on desktop and mobile)
- Transcribe via OpenAI API (`gpt-4o-mini-transcribe`) or locally via Whisper models
- Save audio files to disk with Postgres-backed capture history
- Two-pass transcript cleaning: raw transcription → proper noun correction + formatting
- Per-user and shared proper noun dictionaries
- PWA-ready: add to home screen on iOS/Android for a native-app feel
- Capture history with audio playback

## Architecture

```
Browser (MediaRecorder API)
  ↓ base64 audio via LiveView event
TranscribeLive (LiveView)
  ↓ saves audio to disk, creates capture record
  ↓ ExVox.transcribe/2 in async Task
ExVox
  ├── OpenAI backend → Req HTTP POST
  └── Local backend → Nx.Serving batched inference
  ↓
NounCleanup (GPT-4o-mini second pass)
  ↓ applies proper noun dictionary
CaptureStore (Postgres)
  ↓ persists raw + cleaned transcript, audio path, metadata
```

### Key Modules

| Module | What it does |
|--------|-------------|
| `ExVox` | Core transcription library (separate dep). Format detection, backend dispatch. |
| `TranscribeLive` | LiveView UI. Recording, playback, history panel. |
| `Capture` | Ecto schema for captures (audio_path, raw/cleaned transcript, user, status). |
| `CaptureStore` | Context module for Postgres CRUD on captures. |
| `NounCleanup` | GPT-4o-mini post-processing pass for proper nouns + formatting. |
| `ServingManager` | GenServer managing Nx.Serving lifecycle for local Whisper models. |

### Transcription Backends

| Backend | How it works | Trade-offs |
|---------|-------------|------------|
| `:openai` | Multipart POST to `/v1/audio/transcriptions` | Fast, accurate, requires API key + network. ~$0.006/min. |
| `:local` | Bumblebee loads a HuggingFace Whisper model, Nx/EXLA runs inference | Private, offline, slower, GPU helps. |

The app defaults to `:openai` with `gpt-4o-mini-transcribe`. Switch via config or (eventually) the UI.

### Local Whisper Models

When using the local backend, you can select from multiple model sizes at runtime:

| Model | Parameters | VRAM | Speed | Quality |
|-------|-----------|------|-------|---------|
| `openai/whisper-tiny` | 39M | ~1GB | Fastest | Good for quick captures |
| `openai/whisper-small` | 244M | ~2GB | Fast | Default. Solid accuracy. |
| `openai/whisper-medium` | 769M | ~5GB | Moderate | Better for noisy audio |
| `openai/whisper-large-v3` | 1.5B | ~10GB | Slow | Best quality, needs GPU |

Models are loaded/unloaded at runtime via the ServingManager. Progress is broadcast over PubSub.

## Setup

### Prerequisites

- **Elixir** 1.15+ (recommend asdf: `asdf install elixir 1.17.3`)
- **Erlang/OTP** 26+ (`asdf install erlang 27.2`)
- **PostgreSQL** (any recent version)
- **ffmpeg** (required for local backend audio conversion)
- **OpenAI API key** (for the cloud backend)

### Quick Start

```bash
git clone https://github.com/jakedjohnson/ex_vox_demo.git
cd ex_vox_demo

# Create config/dev.secrets.exs with your API key:
cat > config/dev.secrets.exs << 'EOF'
import Config

config :ex_vox,
  api_key: "sk-..."
EOF

# Install, create DB, build assets, start:
mix setup
mix phx.server
```

Visit [localhost:4000](http://localhost:4000). Hit record. Talk. See text.

### Configuration

Backend and model defaults in `config/config.exs`:

```elixir
config :ex_vox,
  backend: :openai,
  model: "gpt-4o-mini-transcribe",
  language: "en",
  local_model: "openai/whisper-small"
```

### Running on a Server (Tailscale + HTTPS)

If you're running this on a home server behind Tailscale:

```bash
# Generate a TLS cert for your Tailscale hostname
sudo tailscale cert gooey-tower.tail1234.ts.net

# Configure Phoenix to serve HTTPS (see config/dev.exs)
# Point to the cert files, bind to port 4021

# Optional: systemd service for auto-start
# See the systemd section below
```

HTTPS is required for browser microphone access on mobile devices.

### systemd (Optional)

For always-on hosting (Linux server):

```ini
[Unit]
Description=ExVox Server
After=network.target postgresql.service

[Service]
Type=simple
User=your-user
WorkingDirectory=/path/to/ex_vox_demo
EnvironmentFile=/path/to/.env
ExecStart=/path/to/mix phx.server
Restart=always

[Install]
WantedBy=default.target
```

## Proper Nouns

The proper noun system teaches the transcriber your vocabulary. After the initial transcription, a second pass (GPT-4o-mini) corrects names, places, and terms using your dictionary.

Nouns can be:
- **Personal** (scoped to your user): your inside jokes, your pet names, your project codenames
- **Shared** (visible to all users on the instance): household names, shared projects, neighborhood landmarks

Currently managed via the database. A CRUD UI is next on the list.

### Example

Without proper nouns: *"I was talking to zay about the gooey tower and the ex box demo"*

With proper nouns: *"I was talking to Ze about the Gooey Tower and the ExVox demo"*

## For Collaborators / Agent Interop

This repo is designed to be hackable by both humans and their agents. If you're Ze (or anyone else who found this):

1. **Fork or clone.** Run it locally. The OpenAI backend works out of the box with just an API key.
2. **Try local transcription.** If you have a GPU or Apple Silicon, the `:local` backend runs Whisper entirely on your machine. No API calls, no network, no cost.
3. **Add your proper nouns.** Seed the database with your people and places. The cleanup pass gets dramatically better.
4. **Build on it.** The Elixir/Phoenix stack is intentionally simple. One LiveView, one GenServer, one Ecto schema. Add features, break things, PR them back.

### Ideas for Agent-to-Agent Collaboration

- **Shared proper noun dictionaries** — export/import noun lists between instances
- **Capture format standardization** — agreed-upon metadata schema so your agent and my agent can exchange transcripts
- **Local model benchmarks** — compare Whisper model accuracy across different hardware
- **Pipeline plugins** — post-transcription hooks (summarization, tagging, routing to different systems)

## Stack

- **[Phoenix](https://www.phoenixframework.org/)** 1.8 / **[LiveView](https://hexdocs.pm/phoenix_live_view)** 1.1 — real-time UI
- **[ExVox](https://github.com/jakedjohnson/ex_vox)** — audio transcription client
- **[Bumblebee](https://github.com/elixir-nx/bumblebee)** / **[Nx](https://github.com/elixir-nx/nx)** / **[EXLA](https://github.com/elixir-nx/nx/tree/main/exla)** — on-device ML
- **PostgreSQL** — capture persistence
- **Tailwind CSS** — styling

## License

MIT
