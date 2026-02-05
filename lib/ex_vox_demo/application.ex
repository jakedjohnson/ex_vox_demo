defmodule ExVoxDemo.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ExVoxDemoWeb.Telemetry,
      ExVoxDemo.Repo,
      {DNSCluster, query: Application.get_env(:ex_vox_demo, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ExVoxDemo.PubSub},
      # Start a worker by calling: ExVoxDemo.Worker.start_link(arg)
      # {ExVoxDemo.Worker, arg},
      # Start to serve requests, typically the last entry
      ExVoxDemoWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ExVoxDemo.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} = result ->
        maybe_start_local_serving_async(pid)
        result

      other ->
        other
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ExVoxDemoWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp maybe_start_local_serving_async(supervisor) do
    if Application.get_env(:ex_vox, :backend) in [:local, :hybrid] do
      Task.start(fn ->
        model = Application.get_env(:ex_vox, :local_model, "openai/whisper-small")

        child =
          {Nx.Serving,
           serving: ExVox.Local.serving(model: model), name: ExVox.Serving, batch_timeout: 100}

        _ = Supervisor.start_child(supervisor, child)
      end)
    end
  end
end
