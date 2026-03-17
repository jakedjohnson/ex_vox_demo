defmodule ExVoxDemo.Repo.Migrations.CreateCaptures do
  use Ecto.Migration

  def change do
    create table(:captures) do
      add :timestamp, :string, null: false
      add :audio_path, :string
      add :audio_size_bytes, :integer
      add :audio_duration_ms, :integer
      add :transcript_raw, :text
      add :transcript_cleaned, :text
      add :status, :string, null: false, default: "saved"
      add :source, :string, default: "exvox-desktop"
      add :backend, :string
      add :model, :string
      add :processing_time_ms, :integer

      timestamps()
    end

    create index(:captures, [:timestamp])
    create index(:captures, [:status])
  end
end
