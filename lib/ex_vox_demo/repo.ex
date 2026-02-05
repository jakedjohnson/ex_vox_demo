defmodule ExVoxDemo.Repo do
  use Ecto.Repo,
    otp_app: :ex_vox_demo,
    adapter: Ecto.Adapters.Postgres
end
