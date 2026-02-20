# ExVox Demo

A Phoenix LiveView web app for real-time audio transcription, built as a UI wrapper around [ExVox](https://github.com/jakedjohnson/ex_vox) — a minimal Elixir client for speech-to-text that supports both the OpenAI Whisper API and on-device inference via Bumblebee/Nx.

## What Is ExVox?

ExVox is an Elixir library that provides a single entry point for audio transcription:

```elixir
# Cloud transcription via OpenAI
{:ok, result} = ExVox.transcribe(audio_binary, backend: :openai)

# Local transcription via Whisper model running on-device
{:ok, result} = ExVox.transcribe(audio_binary, backend: :local)
```

It handles format detection (via magic bytes), audio-to-tensor conversion (via ffmpeg), and model serving — all behind the same `transcribe/2` interface. The library supports `flac`, `mp3`, `mp4`, `mpeg`, `mpga`, `m4a`, `ogg`, `wav`, and `webm` formats.

### Backends

| Backend | How it works | Trade-offs |
|---------|-------------|------------|
| `:openai` | Multipart POST to `/v1/audio/transcriptions` via Req | Fast, accurate, requires API key + network |
| `:local` | Bumblebee loads a HuggingFace Whisper model, Nx/EXLA runs inference | Private, offline-capable, slower, heavier on resources |

## What This Demo Does

This app wraps ExVox in a single-page LiveView that lets you:

- Record audio from the browser microphone
- Choose between OpenAI API and local Whisper backends
- Select from multiple Whisper model sizes (tiny → large-v3) for local inference
- Load/unload models at runtime with progress tracking
- View transcription results with performance metrics (processing time, realtime speed ratio)

### Architecture

```
Browser (MediaRecorder API)
  ↓ base64 audio via LiveView event
TranscribeLive (LiveView)
  ↓ ExVox.transcribe/2 in async Task
ExVox
  ├── OpenAI backend → Req HTTP POST
  └── Local backend → Nx.Serving batched inference
```

The supervision tree includes a `DynamicSupervisor` for Nx.Serving processes and a `ServingManager` GenServer that manages the model lifecycle — loading weights, featurizer, tokenizer, and JIT compilation with progress updates broadcast over PubSub.

### Key Implementation Details

- **Non-blocking transcription**: Transcription runs in a `Task.async` so the LiveView stays responsive. Results arrive via `handle_info`.
- **Model lifecycle management**: `ServingManager` loads models in a background task, tracks 5-stage progress, and starts the `Nx.Serving` under a `DynamicSupervisor`.
- **PubSub for status updates**: Model loading progress flows from `ServingManager` → PubSub → LiveView → client in real-time.
- **Browser audio capture**: A JavaScript hook uses `MediaRecorder` with codec fallbacks (`webm/opus` → `webm` → `ogg/opus` → `mp4`), mono channel at 16kHz with echo cancellation and noise suppression.

## Setup

### Prerequisites

- Elixir 1.15+
- PostgreSQL
- ffmpeg (required for local backend audio conversion)
- An OpenAI API key (for the OpenAI backend)

### Install & Run

```bash
mix setup
mix phx.server
```

Visit [localhost:4000](http://localhost:4000).

### Configuration

Set your OpenAI API key in `config/dev.secrets.exs`:

```elixir
config :ex_vox,
  api_key: "sk-..."
```

Backend and model defaults are in `config/config.exs`:

```elixir
config :ex_vox,
  backend: :openai,
  model: "gpt-4o-mini-transcribe",
  language: "en",
  local_model: "openai/whisper-small"
```

## Stack

- **[Phoenix](https://www.phoenixframework.org/)** 1.8 / **[LiveView](https://hexdocs.pm/phoenix_live_view)** 1.1 — real-time UI with server-rendered HTML
- **[ExVox](https://github.com/jakedjohnson/ex_vox)** — audio transcription client (OpenAI + local)
- **[Bumblebee](https://github.com/elixir-nx/bumblebee)** / **[Nx](https://github.com/elixir-nx/nx)** / **[EXLA](https://github.com/elixir-nx/nx/tree/main/exla)** — on-device ML inference
- **Tailwind CSS** / **DaisyUI** — styling
