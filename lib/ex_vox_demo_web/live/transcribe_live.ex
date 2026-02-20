defmodule ExVoxDemoWeb.TranscribeLive do
  use ExVoxDemoWeb, :live_view

  alias ExVox.Error
  alias ExVoxDemo.ServingManager
  alias Phoenix.PubSub

  @local_models [
    %{name: "openai/whisper-tiny", ram_gb: 1, speed: "fastest", quality: "basic"},
    %{name: "openai/whisper-small", ram_gb: 2, speed: "fast", quality: "good"},
    %{name: "openai/whisper-medium", ram_gb: 5, speed: "moderate", quality: "great"},
    %{name: "openai/whisper-large-v3", ram_gb: 10, speed: "slow", quality: "best"}
  ]

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
      |> assign(:raw_result, nil)
      |> assign(:error, nil)
      |> assign(:recording, false)
      |> assign(:transcribing, false)
      |> assign(:task_ref, nil)
      |> assign(:backend, backend)
      |> assign(:local_model, local_model)
      |> assign(:local_models, @local_models)
      |> assign(:serving_status, serving_status)
      |> assign(:api_key_configured, api_key not in [nil, ""])
      |> assign(:cache_dir, ServingManager.cache_dir())

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

            {:noreply, assign(socket, transcribing: true, error: nil, task_ref: task.ref)}

          :error ->
            {:noreply, assign(socket, error: "Invalid audio data received.")}
        end
    end
  end

  def handle_event("copy", _params, socket) do
    socket =
      socket
      |> push_event("copy_to_clipboard", %{text: socket.assigns.transcript || ""})

    {:noreply, socket}
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
    if ref == socket.assigns.task_ref do
      Process.demonitor(ref, [:flush])
      require Logger
      Logger.debug("Transcription task result: #{inspect(result)}")

      case result do
        {:ok, %ExVox.Result{} = res} ->
          {:noreply,
           assign(socket,
             transcribing: false,
             transcript: res.text,
             raw_result: res,
             error: nil,
             task_ref: nil
           )}

        {:error, %Error{message: message}} ->
          {:noreply,
           assign(socket,
             transcribing: false,
             transcript: nil,
             raw_result: nil,
             error: message,
             task_ref: nil
           )}

        other ->
          Logger.error("Unexpected transcription result: #{inspect(other)}")

          {:noreply,
           assign(socket,
             transcribing: false,
             transcript: nil,
             raw_result: nil,
             error: "Unexpected transcription result",
             task_ref: nil
           )}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, socket) do
    require Logger
    Logger.error("Transcription task DOWN: #{inspect(reason)}")

    if ref == socket.assigns.task_ref do
      {:noreply,
       assign(socket,
         transcribing: false,
         error: "Transcription failed unexpectedly: #{inspect(reason)}",
         task_ref: nil
       )}
    else
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

  def render(assigns) do
    ~H"""
    <div id="transcribe-root" class="mx-auto max-w-2xl px-6 py-16" phx-hook="Clipboard">
      <div class="text-center">
        <h1 class="text-3xl font-bold tracking-tight">ExVox</h1>
        <p class="mt-1 text-sm text-base-content/50">
          Tap to record · tap again to transcribe
        </p>
      </div>

      <div class="mt-6 flex flex-col items-center gap-3">
        <%!-- Backend toggle --%>
        <div class="join">
          <label class="join-item btn btn-sm" phx-click="set_backend" phx-value-backend="openai">
            <input type="radio" name="backend" checked={@backend == :openai} /> API
          </label>
          <label class="join-item btn btn-sm" phx-click="set_backend" phx-value-backend="local">
            <input type="radio" name="backend" checked={@backend == :local} /> Local
          </label>
        </div>

        <div :if={@backend == :openai and not @api_key_configured} class="alert alert-warning">
          <span>No OpenAI API key configured. Set OPENAI_API_KEY to use API mode.</span>
        </div>

        <%!-- Model selector (local mode) --%>
        <div
          :if={@backend == :local or @serving_status != :idle}
          class="flex flex-wrap items-center gap-2"
        >
          <span class="text-xs text-base-content/50">Model</span>
          <form phx-change="set_local_model">
            <select class="select select-sm" name="local_model">
              <%= for model <- @local_models do %>
                <option value={model.name} selected={model.name == @local_model}>
                  {model.name} (~{model.ram_gb} GB · {model.speed} · {model.quality})
                </option>
              <% end %>
            </select>
          </form>

          <button
            :if={@backend == :local and @local_model != serving_model(@serving_status)}
            type="button"
            class="btn btn-sm"
            phx-click="load_model"
            disabled={serving_loading?(@serving_status)}
          >
            Load model
          </button>

          <button
            :if={@backend == :local and @serving_status != :idle}
            type="button"
            class="btn btn-sm btn-ghost"
            phx-click="stop_model"
          >
            Unload
          </button>
        </div>

        <%!-- Status badge --%>
        <span class={[
          "badge text-xs",
          cond do
            serving_ready?(@serving_status) -> "badge-success"
            serving_loading?(@serving_status) -> "badge-warning"
            serving_error?(@serving_status) -> "badge-error"
            true -> "badge-ghost"
          end
        ]}>
          <%= case @serving_status do %>
            <% :idle -> %>
              <%= if @backend == :openai do %>
                API mode
              <% else %>
                No model loaded
              <% end %>
            <% {:loading, model, _step, elapsed, _progress} -> %>
              Loading {model}… {format_elapsed(elapsed)}
            <% {:ready, model, elapsed} -> %>
              {model} ready
              <span :if={elapsed && elapsed > 0} class="opacity-60">
                (loaded in {format_elapsed(elapsed)})
              </span>
            <% {:error, model, _reason} -> %>
              Failed to load {model}
          <% end %>
        </span>

        <%!-- Loading progress detail --%>
        <div :if={serving_loading?(@serving_status)} class="w-full max-w-sm">
          <div class="flex flex-col gap-2">
            <%!-- Determinate progress bar --%>
            <div class="relative w-full">
              <progress
                class="progress progress-warning w-full"
                value={progress_percent(@serving_status)}
                max="100"
              >
              </progress>
              <span class="absolute inset-0 flex items-center justify-center text-[10px] font-semibold text-base-content/70">
                {progress_percent(@serving_status)}%
              </span>
            </div>

            <%!-- Current step label --%>
            <p
              :if={loading_step(@serving_status)}
              class="text-xs text-base-content/50 text-center"
            >
              {ServingManager.step_label(loading_step(@serving_status))}
            </p>
            <p
              :if={loading_step(@serving_status) == nil}
              class="text-xs text-base-content/50 text-center"
            >
              Initializing…
            </p>

            <%!-- Elapsed time --%>
            <p
              :if={loading_elapsed(@serving_status) > 0}
              class="text-xs text-base-content/30 text-center tabular-nums"
            >
              {format_elapsed(loading_elapsed(@serving_status))} elapsed
            </p>

            <p class="text-xs text-base-content/30 text-center">
              First load downloads the model. Subsequent loads use cache.
            </p>
          </div>
        </div>

        <%!-- Cache directory info (shown in local mode when idle or ready) --%>
        <div
          :if={@backend == :local and not serving_loading?(@serving_status)}
          class="w-full max-w-sm"
        >
          <details class="mt-1">
            <summary class="cursor-pointer text-xs text-base-content/30 hover:text-base-content/50 transition-colors text-center">
              Model cache location
            </summary>
            <div class="mt-1 rounded-box bg-base-200 px-3 py-2">
              <code class="text-[11px] text-base-content/60 break-all">{@cache_dir}</code>
              <p class="mt-1 text-[11px] text-base-content/30">
                Models are cached here after first download. Delete this folder to force re-download.
              </p>
            </div>
          </details>
        </div>

        <div :if={serving_error?(@serving_status)} class="text-xs text-error">
          <%= case @serving_status do %>
            <% {:error, _model, reason} -> %>
              {inspect(reason)}
          <% end %>
        </div>
      </div>

      <%!-- Record button --%>
      <div
        id="audio-recorder"
        class="mt-12 flex flex-col items-center gap-4"
        phx-hook="AudioRecorder"
      >
        <button
          type="button"
          data-toggle-record
          disabled={@transcribing or (@backend == :local and not serving_ready?(@serving_status))}
          class={[
            "relative flex h-24 w-24 items-center justify-center rounded-full transition-all duration-300",
            "focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-offset-base-100",
            cond do
              @transcribing ->
                "bg-base-300 cursor-not-allowed focus:ring-base-300"

              @recording ->
                "bg-error shadow-lg shadow-error/30 focus:ring-error"

              true ->
                "bg-primary hover:scale-105 active:scale-95 shadow-md hover:shadow-lg focus:ring-primary"
            end
          ]}
        >
          <span :if={@recording} class="absolute inset-0 rounded-full bg-error/30 animate-ping" />

          <svg
            :if={!@recording && !@transcribing}
            xmlns="http://www.w3.org/2000/svg"
            viewBox="0 0 24 24"
            fill="currentColor"
            class="h-10 w-10 text-primary-content"
          >
            <path d="M8.25 4.5a3.75 3.75 0 117.5 0v8.25a3.75 3.75 0 11-7.5 0V4.5z" />
            <path d="M6 10.5a.75.75 0 01.75.75v1.5a5.25 5.25 0 1010.5 0v-1.5a.75.75 0 011.5 0v1.5a6.751 6.751 0 01-6 6.709v2.291h3a.75.75 0 010 1.5h-7.5a.75.75 0 010-1.5h3v-2.291a6.751 6.751 0 01-6-6.709v-1.5A.75.75 0 016 10.5z" />
          </svg>

          <svg
            :if={@recording}
            xmlns="http://www.w3.org/2000/svg"
            viewBox="0 0 24 24"
            fill="currentColor"
            class="relative z-10 h-10 w-10 text-error-content"
          >
            <path
              fill-rule="evenodd"
              d="M4.5 7.5a3 3 0 013-3h9a3 3 0 013 3v9a3 3 0 01-3 3h-9a3 3 0 01-3-3v-9z"
              clip-rule="evenodd"
            />
          </svg>

          <svg
            :if={@transcribing}
            class="h-8 w-8 animate-spin text-base-content/40"
            xmlns="http://www.w3.org/2000/svg"
            fill="none"
            viewBox="0 0 24 24"
          >
            <circle
              class="opacity-25"
              cx="12"
              cy="12"
              r="10"
              stroke="currentColor"
              stroke-width="4"
            />
            <path
              class="opacity-75"
              fill="currentColor"
              d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"
            />
          </svg>
        </button>

        <p class="text-xs text-base-content/40">
          <%= cond do %>
            <% @transcribing -> %>
              Transcribing…
            <% @recording -> %>
              Recording · tap to stop
            <% @backend == :local and not serving_ready?(@serving_status) -> %>
              Load a model above to start
            <% true -> %>
              Tap to start
          <% end %>
        </p>
      </div>

      <div :if={@error} class="alert alert-error mt-10">
        <span>{@error}</span>
      </div>

      <div class="alert alert-warning mt-10" id="browser-warning" phx-hook="BrowserCheck">
        <span>
          If transcription isn't working, try using Safari instead of Chrome. Some Chrome versions have audio capture issues.
        </span>
      </div>

      <div :if={@transcript} class="mt-10">
        <div class="flex items-center justify-between">
          <h2 class="text-lg font-semibold">Transcript</h2>
          <button class="btn btn-sm btn-ghost gap-1" type="button" phx-click="copy">
            <svg
              xmlns="http://www.w3.org/2000/svg"
              viewBox="0 0 20 20"
              fill="currentColor"
              class="h-4 w-4"
            >
              <path d="M7 3.5A1.5 1.5 0 018.5 2h3.879a1.5 1.5 0 011.06.44l3.122 3.12A1.5 1.5 0 0117 6.622V12.5a1.5 1.5 0 01-1.5 1.5h-1v-3.379a3 3 0 00-.879-2.121L10.5 5.379A3 3 0 008.379 4.5H7v-1z" />
              <path d="M4.5 6A1.5 1.5 0 003 7.5v9A1.5 1.5 0 004.5 18h7a1.5 1.5 0 001.5-1.5v-5.879a1.5 1.5 0 00-.44-1.06L9.44 6.439A1.5 1.5 0 008.378 6H4.5z" />
            </svg>
            Copy
          </button>
        </div>
        <div class="mt-2 rounded-box bg-base-200 p-4 text-sm leading-relaxed whitespace-pre-wrap">
          {@transcript}
        </div>
      </div>

      <div :if={@raw_result && (Map.get(@raw_result, :audio_duration_ms) || Map.get(@raw_result, :processing_time_ms))} class="mt-4 flex flex-wrap gap-3">
        <div :if={Map.get(@raw_result, :audio_duration_ms)} class="flex items-center gap-1.5 rounded-box bg-base-200 px-3 py-1.5">
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="h-3.5 w-3.5 text-base-content/40">
            <path d="M8.25 4.5a3.75 3.75 0 117.5 0v8.25a3.75 3.75 0 11-7.5 0V4.5z" />
            <path d="M6 10.5a.75.75 0 01.75.75v1.5a5.25 5.25 0 1010.5 0v-1.5a.75.75 0 011.5 0v1.5a6.751 6.751 0 01-6 6.709v2.291h3a.75.75 0 010 1.5h-7.5a.75.75 0 010-1.5h3v-2.291a6.751 6.751 0 01-6-6.709v-1.5A.75.75 0 016 10.5z" />
          </svg>
          <span class="text-xs text-base-content/60 tabular-nums">
            Audio: {format_duration_ms(Map.get(@raw_result, :audio_duration_ms))}
          </span>
        </div>
        <div :if={Map.get(@raw_result, :processing_time_ms)} class="flex items-center gap-1.5 rounded-box bg-base-200 px-3 py-1.5">
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="h-3.5 w-3.5 text-base-content/40">
            <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zm.75-13a.75.75 0 00-1.5 0v5c0 .414.336.75.75.75h4a.75.75 0 000-1.5h-3.25V5z" clip-rule="evenodd" />
          </svg>
          <span class="text-xs text-base-content/60 tabular-nums">
            Processing: {format_duration_ms(Map.get(@raw_result, :processing_time_ms))}
          </span>
        </div>
        <div :if={Map.get(@raw_result, :audio_duration_ms) && Map.get(@raw_result, :processing_time_ms)} class="flex items-center gap-1.5 rounded-box bg-base-200 px-3 py-1.5">
          <span class="text-xs text-base-content/40 tabular-nums">
            {format_speed_ratio(Map.get(@raw_result, :audio_duration_ms), Map.get(@raw_result, :processing_time_ms))}
          </span>
        </div>
      </div>

      <details :if={@raw_result} class="mt-4">
        <summary class="cursor-pointer text-xs text-base-content/40 hover:text-base-content/60 transition-colors">
          API Response
        </summary>
        <pre class="mt-2 rounded-box bg-base-300 p-3 text-xs overflow-x-auto"><code>{inspect(@raw_result, pretty: true)}</code></pre>
      </details>
    </div>
    """
  end
end
