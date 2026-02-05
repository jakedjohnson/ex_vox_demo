defmodule ExVoxDemoWeb.TranscribeLive do
  use ExVoxDemoWeb, :live_view

  alias ExVox.Error

  @local_models [
    "openai/whisper-tiny",
    "openai/whisper-small",
    "openai/whisper-medium",
    "openai/whisper-large-v3"
  ]

  def mount(_params, _session, socket) do
    backend = Application.get_env(:ex_vox, :backend, :openai)
    local_model = Application.get_env(:ex_vox, :local_model, "openai/whisper-small")

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
      |> assign(:serving_ready, serving_ready?(backend))

    if backend == :local and not socket.assigns.serving_ready do
      Process.send_after(self(), :check_serving, 1_000)
    end

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
    case Base.decode64(base64_data) do
      {:ok, binary} ->
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

    socket = assign(socket, backend: backend, serving_ready: serving_ready?(backend))

    if backend == :local and not socket.assigns.serving_ready do
      Process.send_after(self(), :check_serving, 1_000)
    end

    {:noreply, socket}
  end

  def handle_event("set_local_model", %{"local_model" => local_model}, socket) do
    {:noreply, assign(socket, local_model: local_model)}
  end

  def handle_info(:check_serving, socket) do
    ready = serving_ready?(socket.assigns.backend)

    if ready do
      {:noreply, assign(socket, serving_ready: true)}
    else
      Process.send_after(self(), :check_serving, 2_000)
      {:noreply, socket}
    end
  end

  defp serving_ready?(:local), do: Process.whereis(ExVox.Serving) != nil
  defp serving_ready?(_), do: true

  def handle_info({ref, result}, socket) when is_reference(ref) do
    if ref == socket.assigns.task_ref do
      Process.demonitor(ref, [:flush])

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
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, socket) do
    if ref == socket.assigns.task_ref do
      {:noreply,
       assign(socket,
         transcribing: false,
         error: "Transcription failed unexpectedly.",
         task_ref: nil
       )}
    else
      {:noreply, socket}
    end
  end

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
        <div class="join">
          <label class="join-item btn btn-sm" phx-click="set_backend" phx-value-backend="openai">
            <input type="radio" name="backend" checked={@backend == :openai} />
            API
          </label>
          <label class="join-item btn btn-sm" phx-click="set_backend" phx-value-backend="local">
            <input type="radio" name="backend" checked={@backend == :local} />
            Local
          </label>
        </div>

        <div :if={@backend == :local} class="flex items-center gap-2">
          <span class="text-xs text-base-content/50">Model</span>
          <select
            class="select select-sm"
            name="local_model"
            phx-change="set_local_model"
          >
            <%= for model <- @local_models do %>
              <option value={model} selected={model == @local_model}><%= model %></option>
            <% end %>
          </select>
        </div>

        <span class="badge badge-ghost text-xs">
          <%= if @backend == :openai do %>
            API mode
          <% else %>
            <%= if @serving_ready do %>
              Local mode (<%= @local_model %>)
            <% else %>
              Local model loading…
            <% end %>
          <% end %>
        </span>
      </div>

      <div id="audio-recorder" class="mt-12 flex flex-col items-center gap-4" phx-hook="AudioRecorder">
        <button
          type="button"
          data-toggle-record
          disabled={@transcribing}
          class={[
            "relative flex h-24 w-24 items-center justify-center rounded-full transition-all duration-300",
            "focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-offset-base-100",
            cond do
              @transcribing -> "bg-base-300 cursor-not-allowed focus:ring-base-300"
              @recording -> "bg-error shadow-lg shadow-error/30 focus:ring-error"
              true -> "bg-primary hover:scale-105 active:scale-95 shadow-md hover:shadow-lg focus:ring-primary"
            end
          ]}
        >
          <span :if={@recording} class="absolute inset-0 rounded-full bg-error/30 animate-ping" />

          <svg :if={!@recording && !@transcribing} xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" class="h-10 w-10 text-primary-content">
            <path d="M8.25 4.5a3.75 3.75 0 117.5 0v8.25a3.75 3.75 0 11-7.5 0V4.5z" />
            <path d="M6 10.5a.75.75 0 01.75.75v1.5a5.25 5.25 0 1010.5 0v-1.5a.75.75 0 011.5 0v1.5a6.751 6.751 0 01-6 6.709v2.291h3a.75.75 0 010 1.5h-7.5a.75.75 0 010-1.5h3v-2.291a6.751 6.751 0 01-6-6.709v-1.5A.75.75 0 016 10.5z" />
          </svg>

          <svg :if={@recording} xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" class="relative z-10 h-10 w-10 text-error-content">
            <path fill-rule="evenodd" d="M4.5 7.5a3 3 0 013-3h9a3 3 0 013 3v9a3 3 0 01-3 3h-9a3 3 0 01-3-3v-9z" clip-rule="evenodd" />
          </svg>

          <svg :if={@transcribing} class="h-8 w-8 animate-spin text-base-content/40" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
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
            <% true -> %>
              Tap to start
          <% end %>
        </p>
      </div>

      <div :if={@error} class="alert alert-error mt-10">
        <span><%= @error %></span>
      </div>

      <div :if={@transcript} class="mt-10">
        <div class="flex items-center justify-between">
          <h2 class="text-lg font-semibold">Transcript</h2>
          <button class="btn btn-sm btn-ghost gap-1" type="button" phx-click="copy">
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="h-4 w-4">
              <path d="M7 3.5A1.5 1.5 0 018.5 2h3.879a1.5 1.5 0 011.06.44l3.122 3.12A1.5 1.5 0 0117 6.622V12.5a1.5 1.5 0 01-1.5 1.5h-1v-3.379a3 3 0 00-.879-2.121L10.5 5.379A3 3 0 008.379 4.5H7v-1z" />
              <path d="M4.5 6A1.5 1.5 0 003 7.5v9A1.5 1.5 0 004.5 18h7a1.5 1.5 0 001.5-1.5v-5.879a1.5 1.5 0 00-.44-1.06L9.44 6.439A1.5 1.5 0 008.378 6H4.5z" />
            </svg>
            Copy
          </button>
        </div>
        <div class="mt-2 rounded-box bg-base-200 p-4 text-sm leading-relaxed whitespace-pre-wrap">
          <%= @transcript %>
        </div>
      </div>

      <details :if={@raw_result} class="mt-4">
        <summary class="cursor-pointer text-xs text-base-content/40 hover:text-base-content/60 transition-colors">
          API Response
        </summary>
        <pre class="mt-2 rounded-box bg-base-300 p-3 text-xs overflow-x-auto"><code><%= inspect(@raw_result, pretty: true) %></code></pre>
      </details>
    </div>
    """
  end
end
