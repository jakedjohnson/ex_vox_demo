defmodule ExVoxDemo.ServingManager do
  @moduledoc false

  use GenServer

  alias Phoenix.PubSub

  @topic "serving_status"

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
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

  @impl true
  def init(_state) do
    state = %{status: :idle, task_ref: nil, task_model: nil, serving_pid: nil}
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  @impl true
  def handle_cast({:load_model, model}, state) do
    state = stop_serving(state)

    task =
      Task.async(fn ->
        ExVox.Local.serving(model: model)
      end)

    state =
      state
      |> set_status({:loading, model})
      |> Map.put(:task_ref, task.ref)
      |> Map.put(:task_model, model)

    {:noreply, state}
  end

  @impl true
  def handle_cast(:stop_model, state) do
    state =
      state
      |> stop_serving()
      |> set_status(:idle)
      |> Map.put(:task_ref, nil)
      |> Map.put(:task_model, nil)

    {:noreply, state}
  end

  @impl true
  def handle_info({ref, serving}, state) when is_reference(ref) do
    if ref == state.task_ref do
      Process.demonitor(ref, [:flush])

      case DynamicSupervisor.start_child(
             ExVoxDemo.ServingDynSup,
             {Nx.Serving, serving: serving, name: ExVox.Serving, batch_timeout: 100}
           ) do
        {:ok, pid} ->
          state =
            state
            |> Map.put(:serving_pid, pid)
            |> Map.put(:task_ref, nil)
            |> Map.put(:task_model, nil)
            |> set_status({:ready, state.task_model})

          {:noreply, state}

        {:error, reason} ->
          state =
            state
            |> Map.put(:serving_pid, nil)
            |> Map.put(:task_ref, nil)
            |> Map.put(:task_model, nil)
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
        |> Map.put(:task_ref, nil)
        |> Map.put(:task_model, nil)
        |> set_status({:error, state.task_model, reason})

      {:noreply, state}
    else
      {:noreply, state}
    end
  end

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
