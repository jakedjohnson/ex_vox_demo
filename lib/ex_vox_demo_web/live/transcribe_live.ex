defmodule ExVoxDemoWeb.TranscribeLive do
  use ExVoxDemoWeb, :live_view

  alias ExVox.Error
  alias ExVoxDemo.Capture
  alias ExVoxDemo.CaptureStore
  alias ExVoxDemo.NounCleanup
  alias ExVoxDemo.ServingManager
  alias ExVoxDemo.TTS
  alias Phoenix.PubSub

  @local_models [
    %{name: "openai/whisper-tiny", ram_gb: 1, speed: "fastest", quality: "basic"},
    %{name: "openai/whisper-small", ram_gb: 2, speed: "fast", quality: "good"},
    %{name: "openai/whisper-medium", ram_gb: 5, speed: "moderate", quality: "great"},
    %{name: "openai/whisper-large-v3", ram_gb: 10, speed: "slow", quality: "best"}
  ]

  @tts_models ["gpt-4o-mini-tts", "tts-1", "tts-1-hd"]
  @tts_voices ["alloy", "ash", "ballad", "coral", "echo", "fable", "nova", "onyx", "sage", "shimmer"]

  def mount(_params, _session, socket) do
    backend = Application.get_env(:ex_vox, :backend, :openai)
    local_model = Application.get_env(:ex_vox, :local_model, "openai/whisper-small")
    api_key = Application.get_env(:ex_vox, :api_key)
    serving_status = ServingManager.status()

    if connected?(socket) do
      PubSub.subscribe(ExVoxDemo.PubSub, "serving_status")
    end

    socket =
      socket
      |> assign(:transcript, nil)
      |> assign(:cleaned_transcript, nil)
      |> assign(:cleaning, false)
      |> assign(:cleanup_ref, nil)
      |> assign(:saved_audio_path, nil)
      |> assign(:capture_timestamp, nil)
      |> assign(:capture, nil)
      |> assign(:raw_result, nil)
      |> assign(:error, nil)
      |> assign(:recording, false)
      |> assign(:transcribing, false)
      |> assign(:task_ref, nil)
      |> assign(:backend, backend)
      |> assign(:local_model, local_model)
      |> assign(:local_models, @local_models)
      |> assign(:tts_text, "")
      |> assign(:tts_voice, hd(@tts_voices))
      |> assign(:tts_model, hd(@tts_models))
      |> assign(:tts_speaking, false)
      |> assign(:tts_error, nil)
      |> assign(:tts_task_ref, nil)
      |> assign(:tts_models, @tts_models)
      |> assign(:tts_voices, @tts_voices)
      |> assign(:serving_status, serving_status)
      |> assign(:api_key_configured, api_key not in [nil, ""])
      |> assign(:cache_dir, ServingManager.cache_dir())
    history = Capture.list_recent()

    socket =
      socket
      |> assign(:history_count, length(history))
      |> stream(:history, history)

    {:ok, socket}
  end

  def handle_event("recording_started", _params, socket) do
    {:noreply, assign(socket, recording: true, error: nil)}
  end

  def handle_event("recording_stopped", _params, socket) do
    {:noreply, assign(socket, :recording, false)}
  end

  def handle_event("recording_error", %{"message" => message}, socket) do
    {:noreply, assign(socket, error: "Microphone access failed: #{message}", recording: false)}
  end

  def handle_event("audio_recorded", %{"data" => base64_data}, socket) do
    cond do
      socket.assigns.backend == :openai and not socket.assigns.api_key_configured ->
        {:noreply,
         assign(socket,
           error: "No OpenAI API key configured. Set OPENAI_API_KEY or switch to Local mode."
         )}

      socket.assigns.backend == :local and not serving_ready?(socket.assigns.serving_status) ->
        {:noreply, assign(socket, error: "Local model not ready. Load a model first.")}

      true ->
        case Base.decode64(base64_data) do
          {:ok, binary} ->
            require Logger

            {save_result, audio_path, timestamp} =
              case CaptureStore.save_audio(binary) do
                {:ok, path, ts} -> {:ok, path, ts}
                {:error, _reason} -> {:error, nil, nil}
              end

            capture =
              if save_result == :ok do
                case Capture.create_from_audio(timestamp, audio_path, byte_size(binary)) do
                  {:ok, cap} -> cap
                  {:error, _} -> nil
                end
              end

            if save_result != :ok do
              Logger.warning("Audio save failed — proceeding with transcription anyway")
            end

            Logger.debug(
              "Starting transcription with backend=#{socket.assigns.backend}, binary size=#{byte_size(binary)}"
            )

            task =
              Task.async(fn ->
                ExVox.transcribe(binary,
                  backend: socket.assigns.backend,
                  local_model: socket.assigns.local_model
                )
              end)

            {:noreply,
             socket
             |> assign(
               transcribing: true,
               error: nil,
               task_ref: task.ref,
               saved_audio_path: audio_path,
               capture_timestamp: timestamp,
               capture: capture,
               cleaned_transcript: nil,
               cleaning: false,
               cleanup_ref: nil
             )
             |> insert_into_history(capture)}

          :error ->
            {:noreply, assign(socket, error: "Invalid audio data received.")}
        end
    end
  end

  def handle_event("copy", _params, socket) do
    text = socket.assigns.cleaned_transcript || socket.assigns.transcript || ""

    socket =
      socket
      |> push_event("copy_to_clipboard", %{text: text})

    {:noreply, socket}
  end

  def handle_event("set_tts_text", %{"tts_text" => text}, socket) do
    {:noreply, assign(socket, tts_text: text)}
  end

  def handle_event("set_tts_voice", %{"tts_voice" => voice}, socket) do
    {:noreply, assign(socket, tts_voice: voice)}
  end

  def handle_event("set_tts_model", %{"tts_model" => model}, socket) do
    {:noreply, assign(socket, tts_model: model)}
  end

  def handle_event("speak", _params, socket) do
    speak_text(socket, socket.assigns.tts_text)
  end

  def handle_event("speak_transcript", _params, socket) do
    text = socket.assigns.cleaned_transcript || socket.assigns.transcript || ""
    speak_text(socket, text)
  end

  def handle_event("retranscribe", %{"id" => id_str}, socket) do
    id = String.to_integer(id_str)
    cap = ExVoxDemo.Repo.get!(Capture, id)

    cond do
      socket.assigns.backend == :openai and not socket.assigns.api_key_configured ->
        {:noreply, assign(socket, error: "No OpenAI API key configured.")}

      socket.assigns.backend == :local and not serving_ready?(socket.assigns.serving_status) ->
        {:noreply, assign(socket, error: "Local model not ready.")}

      cap.audio_path == nil ->
        {:noreply, assign(socket, error: "No audio file for this capture.")}

      true ->
        case File.read(cap.audio_path) do
          {:ok, binary} ->
            task =
              Task.async(fn ->
                ExVox.transcribe(binary,
                  backend: socket.assigns.backend,
                  local_model: socket.assigns.local_model
                )
              end)

            {:noreply,
             socket
             |> assign(
               transcribing: true,
               error: nil,
               task_ref: task.ref,
               saved_audio_path: cap.audio_path,
               capture_timestamp: cap.timestamp,
               capture: cap,
               transcript: nil,
               cleaned_transcript: nil,
               cleaning: false,
               cleanup_ref: nil
             )}

          {:error, reason} ->
            {:noreply, assign(socket, error: "Cannot read audio file: #{inspect(reason)}")}
        end
    end
  end

  def handle_event("set_backend", %{"backend" => backend}, socket) do
    backend =
      case backend do
        "local" -> :local
        _ -> :openai
      end

    {:noreply, assign(socket, backend: backend)}
  end

  def handle_event("set_local_model", %{"local_model" => local_model}, socket) do
    {:noreply, assign(socket, local_model: local_model)}
  end

  def handle_event("load_model", _params, socket) do
    _ = ServingManager.load_model(socket.assigns.local_model)

    {:noreply,
     assign(socket, serving_status: {:loading, socket.assigns.local_model, nil, 0, 0.0})}
  end

  def handle_event("stop_model", _params, socket) do
    _ = ServingManager.stop_model()
    {:noreply, assign(socket, serving_status: :idle)}
  end

  def handle_info({:serving_status, status}, socket) do
    {:noreply, assign(socket, serving_status: status)}
  end

  def handle_info({ref, result}, socket) when is_reference(ref) do
    cond do
      ref == socket.assigns.task_ref ->
      Process.demonitor(ref, [:flush])
      require Logger
      Logger.debug("Transcription task result: #{inspect(result)}")

      case result do
        {:ok, %ExVox.Result{} = res} ->
          if socket.assigns.capture_timestamp do
            CaptureStore.save_transcript(socket.assigns.capture_timestamp, res.text)
          end

          capture =
            if socket.assigns.capture do
              case Capture.mark_transcribed(socket.assigns.capture.id, res.text, res) do
                {:ok, cap} -> cap
                _ -> socket.assigns.capture
              end
            end

          cleanup_task =
            Task.async(fn ->
              NounCleanup.cleanup(res.text)
            end)

          {:noreply,
           socket
           |> assign(
             transcribing: false,
             transcript: res.text,
             raw_result: res,
             error: nil,
             task_ref: nil,
             cleaning: true,
             cleanup_ref: cleanup_task.ref,
             capture: capture
           )
           |> update_in_history(capture)}

        {:error, %Error{message: message}} ->
          {:noreply,
           assign(socket,
             transcribing: false,
             transcript: nil,
             raw_result: nil,
             error: "Transcription failed: #{message}. Audio saved to disk.",
             task_ref: nil
           )}

        other ->
          Logger.error("Unexpected transcription result: #{inspect(other)}")

          {:noreply,
           assign(socket,
             transcribing: false,
             transcript: nil,
             raw_result: nil,
             error: "Unexpected transcription result. Audio saved to disk.",
             task_ref: nil
           )}
      end
      ref == socket.assigns.cleanup_ref ->
        Process.demonitor(ref, [:flush])

        case result do
          {:ok, cleaned} ->
            if socket.assigns.capture_timestamp do
              CaptureStore.save_cleaned_transcript(
                socket.assigns.capture_timestamp,
                socket.assigns.transcript,
                cleaned
              )
            end

            capture =
              if socket.assigns.capture do
                case Capture.mark_cleaned(socket.assigns.capture.id, cleaned) do
                  {:ok, cap} -> cap
                  _ -> socket.assigns.capture
                end
              end

            {:noreply,
             socket
             |> assign(
               cleaned_transcript: cleaned,
               cleaning: false,
               cleanup_ref: nil,
               capture: capture
             )
             |> update_in_history(capture)}

          {:error, _reason} ->
            {:noreply,
             assign(socket,
               cleaning: false,
               cleanup_ref: nil
             )}
        end

      ref == socket.assigns.tts_task_ref ->
        Process.demonitor(ref, [:flush])

        case result do
          {:ok, audio_binary} when is_binary(audio_binary) ->
            base64_audio = Base.encode64(audio_binary)

            {:noreply,
             socket
             |> push_event("audio_playback", %{base64: base64_audio, format: "mp3"})
             |> assign(tts_speaking: false, tts_error: nil, tts_task_ref: nil)}

          {:error, reason} ->
            {:noreply,
             assign(socket, tts_speaking: false, tts_error: format_tts_error(reason), tts_task_ref: nil)}

          other ->
            {:noreply,
             assign(socket,
               tts_speaking: false,
               tts_error: "Unexpected TTS result: #{inspect(other)}",
               tts_task_ref: nil
             )}
        end

      true ->
        {:noreply, socket}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, socket) do
    require Logger
    Logger.error("Transcription task DOWN: #{inspect(reason)}")

    cond do
      ref == socket.assigns.task_ref ->
        {:noreply,
         assign(socket,
           transcribing: false,
           error: "Transcription failed unexpectedly: #{inspect(reason)}",
           task_ref: nil
         )}

      ref == socket.assigns.cleanup_ref ->
        {:noreply,
         assign(socket,
           cleaning: false,
           cleanup_ref: nil
         )}

      ref == socket.assigns.tts_task_ref ->
        {:noreply,
         assign(socket,
           tts_speaking: false,
           tts_error: "TTS failed unexpectedly: #{inspect(reason)}",
           tts_task_ref: nil
         )}

      true ->
        {:noreply, socket}
    end
  end

  # --- Status helpers ---

  defp serving_ready?({:ready, _model, _elapsed}), do: true
  defp serving_ready?(_), do: false

  defp serving_loading?({:loading, _model, _step, _elapsed, _progress}), do: true
  defp serving_loading?(_), do: false

  defp serving_error?({:error, _model, _reason}), do: true
  defp serving_error?(_), do: false

  defp serving_model({:loading, model, _step, _elapsed, _progress}), do: model
  defp serving_model({:ready, model, _elapsed}), do: model
  defp serving_model({:error, model, _reason}), do: model
  defp serving_model(_), do: nil

  defp loading_step({:loading, _model, step, _elapsed, _progress}), do: step
  defp loading_step(_), do: nil

  defp loading_elapsed({:loading, _model, _step, elapsed, _progress}), do: elapsed
  defp loading_elapsed(_), do: 0

  defp loading_progress({:loading, _model, _step, _elapsed, progress}), do: progress
  defp loading_progress(_), do: 0.0

  defp progress_percent(status), do: round(loading_progress(status) * 100)

  defp format_elapsed(0), do: ""
  defp format_elapsed(seconds) when seconds < 60, do: "#{seconds}s"

  defp format_elapsed(seconds) do
    m = div(seconds, 60)
    s = rem(seconds, 60)
    "#{m}m #{s}s"
  end

  defp format_duration_ms(ms) when is_number(ms) and ms < 1000, do: "#{ms}ms"

  defp format_duration_ms(ms) when is_number(ms) do
    seconds = ms / 1000

    if seconds < 60 do
      "#{Float.round(seconds, 1)}s"
    else
      m = trunc(seconds / 60)
      s = Float.round(seconds - m * 60, 1)
      "#{m}m #{s}s"
    end
  end

  defp format_duration_ms(_), do: ""

  defp format_speed_ratio(audio_ms, processing_ms) when processing_ms > 0 do
    ratio = Float.round(audio_ms / processing_ms, 1)
    "#{ratio}x realtime"
  end

  defp format_speed_ratio(_, _), do: ""

  defp speak_text(socket, text) do
    cond do
      socket.assigns.backend == :openai and not socket.assigns.api_key_configured ->
        {:noreply,
         assign(socket,
           tts_error: "No OpenAI API key configured. Set OPENAI_API_KEY to use TTS.",
           tts_speaking: false
         )}

      String.trim(text) == "" ->
        {:noreply, assign(socket, tts_error: "Enter some text to speak.", tts_speaking: false)}

      true ->
        task =
          Task.async(fn ->
            TTS.synthesize(text,
              model: socket.assigns.tts_model,
              voice: socket.assigns.tts_voice,
              format: "mp3"
            )
          end)

        {:noreply, assign(socket, tts_speaking: true, tts_error: nil, tts_task_ref: task.ref)}
    end
  end

  defp insert_into_history(socket, nil), do: socket

  defp insert_into_history(socket, capture) do
    socket
    |> assign(:history_count, socket.assigns.history_count + 1)
    |> stream_insert(:history, capture, at: 0)
  end

  defp update_in_history(socket, nil), do: socket

  defp update_in_history(socket, capture) do
    stream_insert(socket, :history, capture)
  end

  defp display_transcript(nil, raw), do: raw
  defp display_transcript(cleaned, _raw), do: cleaned

  defp format_bytes(nil), do: ""
  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp format_tts_error({:http_error, status, body}) do
    "TTS failed (#{status}): #{inspect(body)}"
  end

  defp format_tts_error(:missing_api_key), do: "No OpenAI API key configured."
  defp format_tts_error(:empty_text), do: "Enter some text to speak."
  defp format_tts_error(other), do: "TTS failed: #{inspect(other)}"

  def render(assigns) do
    ~H"""
    <div id="transcribe-root" class="mx-auto max-w-7xl px-4 sm:px-6 py-8" phx-hook="Clipboard">
      <div id="audio-playback" phx-hook="AudioPlayback"></div>

      <div class="flex flex-col lg:flex-row gap-8">
        <%!-- Left column: recorder + current capture --%>
        <div class="w-full lg:w-[420px] lg:shrink-0">
          <header class="flex items-center justify-between">
            <h1 class="text-xl font-bold tracking-tight">ExVox</h1>
            <span class={[
              "badge badge-sm",
              cond do
                serving_ready?(@serving_status) -> "badge-success"
                serving_loading?(@serving_status) -> "badge-warning"
                serving_error?(@serving_status) -> "badge-error"
                @backend == :openai and @api_key_configured -> "badge-ghost"
                @backend == :openai -> "badge-warning"
                true -> "badge-ghost"
              end
            ]}>
              <%= case @serving_status do %>
                <% :idle -> %>
                  <%= if @backend == :openai do %>
                    <%= if @api_key_configured, do: "API ready", else: "No API key" %>
                  <% else %>
                    No model loaded
                  <% end %>
                <% {:loading, _model, _step, _elapsed, _progress} -> %>
                  Loading…
                <% {:ready, model, _elapsed} -> %>
                  {model}
                <% {:error, _model, _reason} -> %>
                  Error
              <% end %>
            </span>
          </header>

          <div
            id="audio-recorder"
            class="mt-10 flex flex-col items-center gap-3"
            phx-hook="AudioRecorder"
          >
            <button
              type="button"
              data-toggle-record
              disabled={@transcribing or (@backend == :local and not serving_ready?(@serving_status))}
              class={[
                "relative flex h-20 w-20 items-center justify-center rounded-full transition-all duration-300",
                "focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-offset-base-100",
                cond do
                  @transcribing -> "bg-base-300 cursor-not-allowed"
                  @recording -> "bg-error shadow-lg shadow-error/30 focus:ring-error"
                  true -> "bg-primary hover:scale-105 active:scale-95 shadow-md hover:shadow-lg focus:ring-primary"
                end
              ]}
            >
              <span :if={@recording} class="absolute inset-0 rounded-full bg-error/30 animate-ping" />
              <svg
                :if={!@recording && !@transcribing}
                xmlns="http://www.w3.org/2000/svg"
                viewBox="0 0 24 24"
                fill="currentColor"
                class="h-8 w-8 text-primary-content"
              >
                <path d="M8.25 4.5a3.75 3.75 0 117.5 0v8.25a3.75 3.75 0 11-7.5 0V4.5z" />
                <path d="M6 10.5a.75.75 0 01.75.75v1.5a5.25 5.25 0 1010.5 0v-1.5a.75.75 0 011.5 0v1.5a6.751 6.751 0 01-6 6.709v2.291h3a.75.75 0 010 1.5h-7.5a.75.75 0 010-1.5h3v-2.291a6.751 6.751 0 01-6-6.709v-1.5A.75.75 0 016 10.5z" />
              </svg>
              <svg
                :if={@recording}
                xmlns="http://www.w3.org/2000/svg"
                viewBox="0 0 24 24"
                fill="currentColor"
                class="relative z-10 h-8 w-8 text-error-content"
              >
                <path
                  fill-rule="evenodd"
                  d="M4.5 7.5a3 3 0 013-3h9a3 3 0 013 3v9a3 3 0 01-3 3h-9a3 3 0 01-3-3v-9z"
                  clip-rule="evenodd"
                />
              </svg>
              <svg
                :if={@transcribing}
                class="h-7 w-7 animate-spin text-base-content/40"
                xmlns="http://www.w3.org/2000/svg"
                fill="none"
                viewBox="0 0 24 24"
              >
                <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4" />
                <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" />
              </svg>
            </button>
            <p class="text-xs text-base-content/40">
              <%= cond do %>
                <% @transcribing -> %>
                  Transcribing…
                <% @recording -> %>
                  Recording · tap to stop
                <% @backend == :local and not serving_ready?(@serving_status) -> %>
                  Load a model in settings
                <% true -> %>
                  Tap to record
              <% end %>
            </p>
          </div>

          <div :if={@error} class="mt-6 rounded-box bg-error/10 border border-error/20 px-4 py-3 text-sm text-error">
            <div>{@error}</div>
            <button
              :if={@capture}
              type="button"
              class="btn btn-xs btn-warning mt-2"
              phx-click="retranscribe"
              phx-value-id={@capture.id}
              disabled={@transcribing}
            >
              Retry transcription
            </button>
          </div>

          <div :if={@saved_audio_path || @transcript} class="mt-6 rounded-box border border-base-content/10 overflow-hidden">
            <div :if={@saved_audio_path} class="bg-base-200/50 p-4 space-y-3">
              <div class="flex items-center justify-between">
                <div class="flex items-center gap-2">
                  <span class="flex h-6 w-6 items-center justify-center rounded-full bg-success/20">
                    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="h-3.5 w-3.5 text-success">
                      <path fill-rule="evenodd" d="M8 15A7 7 0 1 0 8 1a7 7 0 0 0 0 14Zm3.844-8.791a.75.75 0 0 0-1.188-.918l-3.7 4.79-1.649-1.833a.75.75 0 1 0-1.114 1.004l2.25 2.5a.75.75 0 0 0 1.15-.043l4.25-5.5Z" clip-rule="evenodd" />
                    </svg>
                  </span>
                  <span class="text-sm font-medium">Audio saved</span>
                </div>
                <span :if={@capture} class="text-[11px] text-base-content/30 tabular-nums">
                  {format_bytes(@capture.audio_size_bytes)}
                </span>
              </div>

              <audio controls class="w-full h-10" src={"/captures/audio/#{Path.basename(@saved_audio_path)}"}>
                Your browser does not support audio playback.
              </audio>

              <div class="flex items-center gap-2 text-[11px] text-base-content/30">
                <code class="break-all">{Path.basename(@saved_audio_path)}</code>
                <span :if={@capture}>· id:{@capture.id}</span>
              </div>
            </div>

            <.pipeline_status
              saved={@saved_audio_path != nil}
              transcribed={@transcript != nil}
              transcribing={@transcribing}
              cleaned={@cleaned_transcript != nil}
              cleaning={@cleaning}
            />

            <details :if={@transcript} open class="group" phx-mounted={JS.ignore_attributes(["open"])}>
              <summary class="cursor-pointer px-4 py-2.5 text-xs text-base-content/50 hover:text-base-content/70 border-t border-base-content/5 flex items-center justify-between transition-colors">
                <div class="flex items-center gap-1.5">
                  <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="h-3.5 w-3.5 transition-transform group-open:rotate-90">
                    <path fill-rule="evenodd" d="M6.22 4.22a.75.75 0 0 1 1.06 0l3.25 3.25a.75.75 0 0 1 0 1.06l-3.25 3.25a.75.75 0 0 1-1.06-1.06L8.94 8 6.22 5.28a.75.75 0 0 1 0-1.06Z" clip-rule="evenodd" />
                  </svg>
                  Transcript
                  <span :if={@cleaning} class="text-warning/60 animate-pulse">· cleaning…</span>
                  <span :if={@cleaned_transcript} class="text-success/60">· cleaned</span>
                </div>
                <div class="flex items-center gap-1">
                  <span :if={@raw_result && Map.get(@raw_result, :audio_duration_ms)} class="text-[11px] text-base-content/30 tabular-nums">
                    {format_duration_ms(Map.get(@raw_result, :audio_duration_ms))} ·
                    {format_duration_ms(Map.get(@raw_result, :processing_time_ms))} ·
                    {format_speed_ratio(Map.get(@raw_result, :audio_duration_ms), Map.get(@raw_result, :processing_time_ms))}
                  </span>
                </div>
              </summary>
              <div class="px-4 pb-4">
                <div class="rounded-box bg-base-200 p-4 text-sm leading-relaxed whitespace-pre-wrap">
                  {display_transcript(@cleaned_transcript, @transcript)}
                </div>
                <div class="mt-2 flex items-center justify-end gap-1">
                  <button type="button" class="btn btn-xs btn-ghost" phx-click="speak_transcript" disabled={@tts_speaking}>
                    Speak
                  </button>
                  <button type="button" class="btn btn-xs btn-ghost" phx-click="copy">
                    Copy
                  </button>
                </div>
              </div>
            </details>
          </div>

          <div class="mt-8">
            <form phx-change="set_tts_text">
              <textarea
                name="tts_text"
                class="textarea textarea-bordered w-full min-h-[100px] text-sm"
                placeholder="Paste or type anything here…"
                phx-debounce="300"
              ><%= @tts_text %></textarea>
            </form>
            <div class="mt-2 flex items-center justify-between gap-2">
              <div class="flex items-center gap-2">
                <form phx-change="set_tts_voice">
                  <select class="select select-xs" name="tts_voice">
                    <%= for voice <- @tts_voices do %>
                      <option value={voice} selected={voice == @tts_voice}>{voice}</option>
                    <% end %>
                  </select>
                </form>
                <form phx-change="set_tts_model">
                  <select class="select select-xs" name="tts_model">
                    <%= for model <- @tts_models do %>
                      <option value={model} selected={model == @tts_model}>{model}</option>
                    <% end %>
                  </select>
                </form>
              </div>
              <button
                type="button"
                class="btn btn-sm btn-primary"
                phx-click="speak"
                disabled={@tts_speaking}
              >
                <%= if @tts_speaking, do: "Speaking…", else: "Speak" %>
              </button>
            </div>
            <div :if={@tts_error} class="mt-2 text-xs text-error">
              {@tts_error}
            </div>
          </div>

          <details id="settings-panel" class="mt-10" phx-mounted={JS.ignore_attributes(["open"])}>
            <summary class="cursor-pointer text-xs text-base-content/30 hover:text-base-content/50 transition-colors flex items-center gap-1.5">
              <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="h-3.5 w-3.5">
                <path fill-rule="evenodd" d="M7.84 1.804A1 1 0 018.82 1h2.36a1 1 0 01.98.804l.331 1.652a6.993 6.993 0 011.929 1.115l1.598-.54a1 1 0 011.186.447l1.18 2.044a1 1 0 01-.205 1.251l-1.267 1.113a7.047 7.047 0 010 2.228l1.267 1.113a1 1 0 01.206 1.25l-1.18 2.045a1 1 0 01-1.187.447l-1.598-.54a6.993 6.993 0 01-1.929 1.115l-.33 1.652a1 1 0 01-.98.804H8.82a1 1 0 01-.98-.804l-.331-1.652a6.993 6.993 0 01-1.929-1.115l-1.598.54a1 1 0 01-1.186-.447l-1.18-2.044a1 1 0 01.205-1.251l1.267-1.114a7.05 7.05 0 010-2.227L1.821 7.773a1 1 0 01-.206-1.25l1.18-2.045a1 1 0 011.187-.447l1.598.54A6.993 6.993 0 017.51 3.456l.33-1.652zM10 13a3 3 0 100-6 3 3 0 000 6z" clip-rule="evenodd" />
              </svg>
              Settings
            </summary>
            <div class="mt-3 rounded-box bg-base-200 p-4 space-y-4">
              <div class="flex items-center gap-3">
                <span class="text-xs text-base-content/50 w-16">Backend</span>
                <div class="join">
                  <label class="join-item btn btn-xs" phx-click="set_backend" phx-value-backend="openai">
                    <input type="radio" name="backend" checked={@backend == :openai} /> API
                  </label>
                  <label class="join-item btn btn-xs" phx-click="set_backend" phx-value-backend="local">
                    <input type="radio" name="backend" checked={@backend == :local} /> Local
                  </label>
                </div>
              </div>

              <div :if={@backend == :openai and not @api_key_configured} class="text-xs text-warning">
                No OpenAI API key. Set OPENAI_API_KEY env var.
              </div>

              <div :if={@backend == :local or @serving_status != :idle} class="space-y-3">
                <div class="flex flex-wrap items-center gap-2">
                  <span class="text-xs text-base-content/50 w-16">Model</span>
                  <form phx-change="set_local_model">
                    <select class="select select-xs" name="local_model">
                      <%= for model <- @local_models do %>
                        <option value={model.name} selected={model.name == @local_model}>
                          {model.name} (~{model.ram_gb}GB · {model.speed})
                        </option>
                      <% end %>
                    </select>
                  </form>
                  <button
                    :if={@backend == :local and @local_model != serving_model(@serving_status)}
                    type="button"
                    class="btn btn-xs"
                    phx-click="load_model"
                    disabled={serving_loading?(@serving_status)}
                  >
                    Load
                  </button>
                  <button
                    :if={@backend == :local and @serving_status != :idle}
                    type="button"
                    class="btn btn-xs btn-ghost"
                    phx-click="stop_model"
                  >
                    Unload
                  </button>
                </div>

                <div :if={serving_loading?(@serving_status)} class="space-y-1">
                  <%= if progress_percent(@serving_status) > 0 do %>
                    <progress class="progress progress-warning w-full" value={progress_percent(@serving_status)} max="100" />
                  <% else %>
                    <progress class="progress progress-warning w-full" />
                  <% end %>
                  <p class="text-xs text-base-content/40 text-center">
                    <%= if loading_step(@serving_status) do %>
                      {ServingManager.step_label(loading_step(@serving_status))}
                    <% else %>
                      Initializing…
                    <% end %>
                    <%= if loading_elapsed(@serving_status) > 0 do %>
                      · {format_elapsed(loading_elapsed(@serving_status))}
                    <% end %>
                  </p>
                </div>

                <div :if={serving_error?(@serving_status)} class="text-xs text-error">
                  <%= case @serving_status do %>
                    <% {:error, _model, reason} -> %>
                      {inspect(reason)}
                  <% end %>
                </div>
              </div>

              <div :if={@backend == :local and not serving_loading?(@serving_status)} class="text-[11px] text-base-content/30">
                Cache: <code class="break-all">{@cache_dir}</code>
              </div>

              <details :if={@raw_result} phx-mounted={JS.ignore_attributes(["open"])}>
                <summary class="cursor-pointer text-[11px] text-base-content/30 hover:text-base-content/50">
                  API Response
                </summary>
                <pre class="mt-1 rounded-box bg-base-300 p-2 text-[11px] overflow-x-auto"><code>{inspect(@raw_result, pretty: true)}</code></pre>
              </details>
            </div>
          </details>
        </div>

        <%!-- Right column: capture history --%>
        <div class="flex-1 min-w-0">
          <div class="flex items-center justify-between mb-4">
            <h2 class="text-sm font-semibold text-base-content/60">History</h2>
            <span class="text-[11px] text-base-content/30">{@history_count} captures</span>
          </div>

          <div id="history-list" phx-update="stream" class="space-y-2">
            <details :for={{dom_id, cap} <- @streams.history} id={dom_id} class="group rounded-box border border-base-content/10 overflow-hidden">
                <summary class="cursor-pointer px-4 py-3 flex items-center justify-between hover:bg-base-200/30 transition-colors">
                  <div class="flex items-center gap-2 min-w-0">
                    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="h-3.5 w-3.5 shrink-0 text-base-content/30 transition-transform group-open:rotate-90">
                      <path fill-rule="evenodd" d="M6.22 4.22a.75.75 0 0 1 1.06 0l3.25 3.25a.75.75 0 0 1 0 1.06l-3.25 3.25a.75.75 0 0 1-1.06-1.06L8.94 8 6.22 5.28a.75.75 0 0 1 0-1.06Z" clip-rule="evenodd" />
                    </svg>
                    <code class="text-[11px] text-base-content/50 truncate">{cap.timestamp}</code>
                  </div>
                  <div class="flex items-center gap-2 shrink-0 ml-2">
                    <span class={["text-[10px] px-1.5 py-0.5 rounded",
                      case cap.status do
                        "cleaned" -> "bg-success/10 text-success/70"
                        "transcribed" -> "bg-info/10 text-info/70"
                        "saved" -> "bg-warning/10 text-warning/70"
                        "failed" -> "bg-error/10 text-error/70"
                        _ -> "bg-base-200 text-base-content/40"
                      end
                    ]}>
                      {cap.status}
                    </span>
                    <span class="text-[11px] text-base-content/30 tabular-nums">
                      {format_bytes(cap.audio_size_bytes)}
                    </span>
                  </div>
                </summary>

                <div class="border-t border-base-content/5">
                  <%!-- Audio player --%>
                  <div :if={cap.audio_path} class="px-4 py-3 bg-base-200/30">
                    <audio controls class="w-full h-8" src={"/captures/audio/#{Capture.audio_filename(cap)}"}>
                    </audio>
                  </div>

                  <%!-- Pipeline status --%>
                  <.pipeline_status
                    saved={cap.audio_path != nil}
                    transcribed={cap.transcript_raw != nil}
                    transcribing={false}
                    cleaned={cap.transcript_cleaned != nil}
                    cleaning={false}
                  />

                  <%!-- Transcripts --%>
                  <div :if={cap.transcript_cleaned || cap.transcript_raw} class="px-4 py-3 space-y-3">
                    <div :if={cap.transcript_cleaned}>
                      <div class="text-[10px] uppercase tracking-wider text-success/60 mb-1">Cleaned</div>
                      <div class="rounded-box bg-base-200 p-3 text-sm leading-relaxed whitespace-pre-wrap">
                        {cap.transcript_cleaned}
                      </div>
                    </div>
                    <details :if={cap.transcript_raw && cap.transcript_cleaned} class="group/raw" phx-mounted={JS.ignore_attributes(["open"])}>
                      <summary class="cursor-pointer text-[10px] uppercase tracking-wider text-base-content/30 hover:text-base-content/50">
                        Raw transcript
                      </summary>
                      <div class="mt-1 rounded-box bg-base-200 p-3 text-sm leading-relaxed whitespace-pre-wrap text-base-content/60">
                        {cap.transcript_raw}
                      </div>
                    </details>
                    <div :if={cap.transcript_raw && !cap.transcript_cleaned}>
                      <div class="text-[10px] uppercase tracking-wider text-base-content/40 mb-1">Raw</div>
                      <div class="rounded-box bg-base-200 p-3 text-sm leading-relaxed whitespace-pre-wrap">
                        {cap.transcript_raw}
                      </div>
                    </div>
                  </div>

                  <%!-- Metadata --%>
                  <div class="px-4 py-2 border-t border-base-content/5 flex flex-wrap items-center gap-x-3 gap-y-1 text-[11px] text-base-content/30">
                    <span>id:{cap.id}</span>
                    <span :if={cap.audio_duration_ms}>audio: {format_duration_ms(cap.audio_duration_ms)}</span>
                    <span :if={cap.processing_time_ms}>proc: {format_duration_ms(cap.processing_time_ms)}</span>
                    <span :if={cap.model}>{cap.model}</span>
                    <button
                      :if={cap.status in ["saved", "failed", "cleaning"]}
                      type="button"
                      class="btn btn-xs btn-warning ml-auto"
                      phx-click="retranscribe"
                      phx-value-id={cap.id}
                      disabled={@transcribing}
                    >
                      Retry
                    </button>
                    <button
                      :if={cap.status in ["transcribed", "cleaned"]}
                      type="button"
                      class="btn btn-xs btn-ghost ml-auto"
                      phx-click="retranscribe"
                      phx-value-id={cap.id}
                      disabled={@transcribing}
                    >
                      Re-transcribe
                    </button>
                  </div>
                </div>
              </details>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp pipeline_status(assigns) do
    ~H"""
    <div class="flex items-center gap-0 text-[10px] border-t border-base-content/5">
      <div class={["flex-1 py-1.5 text-center border-r border-base-content/5", if(@saved, do: "text-success/80 bg-success/5", else: "text-base-content/20")]}>
        1. saved
      </div>
      <div class={["flex-1 py-1.5 text-center border-r border-base-content/5",
        cond do
          @transcribed -> "text-success/80 bg-success/5"
          @transcribing -> "text-warning/80 bg-warning/5 animate-pulse"
          true -> "text-base-content/20"
        end
      ]}>
        2. transcribed
      </div>
      <div class={["flex-1 py-1.5 text-center",
        cond do
          @cleaned -> "text-success/80 bg-success/5"
          @cleaning -> "text-warning/80 bg-warning/5 animate-pulse"
          true -> "text-base-content/20"
        end
      ]}>
        3. cleaned
      </div>
    </div>
    """
  end
end
