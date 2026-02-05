# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :ex_vox_demo,
  ecto_repos: [ExVoxDemo.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configures the endpoint
config :ex_vox_demo, ExVoxDemoWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ExVoxDemoWeb.ErrorHTML, json: ExVoxDemoWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: ExVoxDemo.PubSub,
  live_view: [signing_salt: "nRBxM4tl"]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :ex_vox_demo, ExVoxDemo.Mailer, adapter: Swoosh.Adapters.Local

config :ex_vox,
  backend: :openai,
  api_key: System.get_env("OPENAI_API_KEY"),
  model: "gpt-4o-mini-transcribe",
  language: "en",
  local_model: "openai/whisper-small"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  ex_vox_demo: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.7",
  ex_vox_demo: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :mime, :types, %{
  "audio/mp4" => ["m4a"],
  "audio/mpeg" => ["mpga", "mp3"],
  "audio/ogg" => ["ogg"],
  "audio/flac" => ["flac"]
}

config :mime, :extensions, %{
  "mpeg" => "audio/mpeg"
}

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
