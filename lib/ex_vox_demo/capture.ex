defmodule ExVoxDemo.Capture do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias ExVoxDemo.Repo

  schema "captures" do
    field :timestamp, :string
    field :audio_path, :string
    field :audio_size_bytes, :integer
    field :audio_duration_ms, :integer
    field :transcript_raw, :string
    field :transcript_cleaned, :string
    field :status, :string, default: "saved"
    field :source, :string, default: "exvox-desktop"
    field :backend, :string
    field :model, :string
    field :processing_time_ms, :integer

    timestamps()
  end

  def changeset(capture, attrs) do
    capture
    |> cast(attrs, [
      :timestamp, :audio_path, :audio_size_bytes, :audio_duration_ms,
      :transcript_raw, :transcript_cleaned, :status, :source,
      :backend, :model, :processing_time_ms
    ])
    |> validate_required([:timestamp, :status])
  end

  def create_from_audio(timestamp, audio_path, audio_size_bytes) do
    %__MODULE__{}
    |> changeset(%{
      timestamp: timestamp,
      audio_path: audio_path,
      audio_size_bytes: audio_size_bytes,
      status: "saved"
    })
    |> Repo.insert()
  end

  def mark_transcribed(id, raw_text, result) do
    Repo.get!(__MODULE__, id)
    |> changeset(%{
      transcript_raw: raw_text,
      status: "transcribed",
      audio_duration_ms: Map.get(result, :audio_duration_ms),
      processing_time_ms: Map.get(result, :processing_time_ms),
      model: to_string(Map.get(result, :model, "")),
      backend: "openai"
    })
    |> Repo.update()
  end

  def mark_cleaned(id, cleaned_text) do
    Repo.get!(__MODULE__, id)
    |> changeset(%{
      transcript_cleaned: cleaned_text,
      status: "cleaned"
    })
    |> Repo.update()
  end

  def mark_failed(id) do
    Repo.get!(__MODULE__, id)
    |> changeset(%{status: "failed"})
    |> Repo.update()
  end

  def list_recent(limit \\ 20) do
    __MODULE__
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def audio_filename(%__MODULE__{audio_path: path}) when is_binary(path) do
    Path.basename(path)
  end

  def audio_filename(_), do: nil
end
