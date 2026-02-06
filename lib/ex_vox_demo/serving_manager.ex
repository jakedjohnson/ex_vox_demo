defmodule ExVoxDemo.ServingManager do
  @moduledoc false

  use GenServer

  require Logger

  alias Phoenix.PubSub

  @topic "serving_status"

  # Ordered loading steps with their labels and progress weight (0.0–1.0).
  # Model weights are the bulk of the work; compiling is next heaviest.
  @steps [
    {:loading_model, "Downloading & loading model weights", 0.0},
    {:loading_featurizer, "Loading audio featurizer", 0.50},
    {:loading_tokenizer, "Loading tokenizer", 0.60},
    {:loading_generation_config, "Loading generation config", 0.70},
    {:compiling, "Compiling model (JIT)", 0.75}
  ]

  @step_labels Map.new(@steps, fn {key, label, _} -> {key, label} end)
  @step_progress Map.new(@steps, fn {key, _, pct} -> {key, pct} end)

  # Tick interval for live elapsed-time updates during loading (ms)
  @tick_interval_ms 1_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def status do
    GenServer.call(__MODULE__, :status)
  end

  def load_model(model) when is_binary(model) do
    GenServer.cast(__MODULE__, {:load_model, model})
  end

  def stop_model do
    GenServer.cast(__MODULE__, :stop_model)
  end

  @doc "Returns the user-friendly label for a loading step atom."
  def step_label(step), do: Map.get(@step_labels, step, to_string(step))

  @doc "Returns the Bumblebee model cache directory."
  def cache_dir, do: Bumblebee.cache_dir()

  @impl true
  def init(opts) do
    auto_load = Keyword.get(opts, :auto_load, false)

    state = %{
      status: :idle,
      task_ref: nil,
      task_model: nil,
      serving_pid: nil,
      loading_started_at: nil,
      loading_step: nil,
      tick_ref: nil
    }

    Logger.info("[ServingManager] Bumblebee cache dir: #{cache_dir()}")

    if auto_load do
      model = Application.get_env(:ex_vox, :local_model, "openai/whisper-small")
      Logger.info("[ServingManager] Auto-loading model: #{model}")
      send(self(), {:auto_load, model})
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  @impl true
  def handle_cast({:load_model, model}, state) do
    {:noreply, start_loading(state, model)}
  end

  @impl true
  def handle_cast(:stop_model, state) do
    state =
      state
      |> stop_serving()
      |> cancel_tick()
      |> reset_loading_state()
      |> set_status(:idle)

    {:noreply, state}
  end

  @impl true
  def handle_info({:auto_load, model}, state) do
    {:noreply, start_loading(state, model)}
  end

  # Periodic tick to push live elapsed-time updates
  @impl true
  def handle_info(:tick, state) do
    if state.loading_started_at do
      elapsed = loading_elapsed(state)
      progress = step_progress(state.loading_step)

      state =
        state
        |> set_status({:loading, state.task_model, state.loading_step, elapsed, progress})
        |> schedule_tick()

      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  # Progress step updates from ExVox.Local.serving/1
  @impl true
  def handle_info({:loading_step, step}, state) do
    elapsed = loading_elapsed(state)
    progress = step_progress(step)

    Logger.info(
      "[ServingManager] Step: #{step_label(step)} (#{elapsed}s elapsed, #{round(progress * 100)}%)"
    )

    state =
      state
      |> Map.put(:loading_step, step)
      |> set_status({:loading, state.task_model, step, elapsed, progress})

    {:noreply, state}
  end

  @impl true
  def handle_info({ref, serving}, state) when is_reference(ref) do
    if ref == state.task_ref do
      Process.demonitor(ref, [:flush])
      elapsed = loading_elapsed(state)

      Logger.info("[ServingManager] Model ready in #{elapsed}s — cached at: #{cache_dir()}")

      state = cancel_tick(state)

      case DynamicSupervisor.start_child(
             ExVoxDemo.ServingDynSup,
             {Nx.Serving, serving: serving, name: ExVox.Serving, batch_timeout: 100}
           ) do
        {:ok, pid} ->
          state =
            state
            |> Map.put(:serving_pid, pid)
            |> reset_loading_state()
            |> set_status({:ready, state.task_model, elapsed})

          {:noreply, state}

        {:error, reason} ->
          state =
            state
            |> Map.put(:serving_pid, nil)
            |> reset_loading_state()
            |> set_status({:error, state.task_model, reason})

          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    if ref == state.task_ref do
      state =
        state
        |> cancel_tick()
        |> reset_loading_state()
        |> set_status({:error, state.task_model, reason})

      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  # --- Private helpers ---

  defp start_loading(state, model) do
    state = state |> stop_serving() |> cancel_tick()
    manager = self()

    progress_fn = fn step ->
      send(manager, {:loading_step, step})
    end

    task =
      Task.async(fn ->
        ExVox.Local.serving(model: model, progress_fn: progress_fn)
      end)

    state
    |> Map.put(:task_ref, task.ref)
    |> Map.put(:task_model, model)
    |> Map.put(:loading_started_at, System.monotonic_time(:second))
    |> Map.put(:loading_step, nil)
    |> set_status({:loading, model, nil, 0, 0.0})
    |> schedule_tick()
  end

  defp reset_loading_state(state) do
    state
    |> Map.put(:task_ref, nil)
    |> Map.put(:task_model, nil)
    |> Map.put(:loading_started_at, nil)
    |> Map.put(:loading_step, nil)
  end

  defp schedule_tick(state) do
    ref = Process.send_after(self(), :tick, @tick_interval_ms)
    %{state | tick_ref: ref}
  end

  defp cancel_tick(%{tick_ref: nil} = state), do: state

  defp cancel_tick(%{tick_ref: ref} = state) when is_reference(ref) do
    Process.cancel_timer(ref)
    %{state | tick_ref: nil}
  end

  # Handle state from before hot-reload added :tick_ref
  defp cancel_tick(state), do: Map.put(state, :tick_ref, nil)

  defp loading_elapsed(%{loading_started_at: nil}), do: 0

  defp loading_elapsed(%{loading_started_at: started_at}) do
    System.monotonic_time(:second) - started_at
  end

  defp step_progress(nil), do: 0.0
  defp step_progress(step), do: Map.get(@step_progress, step, 0.0)

  defp stop_serving(state) do
    case state.serving_pid do
      nil ->
        state

      pid ->
        _ = DynamicSupervisor.terminate_child(ExVoxDemo.ServingDynSup, pid)
        %{state | serving_pid: nil}
    end
  end

  defp set_status(state, status) do
    _ = PubSub.broadcast(ExVoxDemo.PubSub, @topic, {:serving_status, status})
    %{state | status: status}
  end
end
