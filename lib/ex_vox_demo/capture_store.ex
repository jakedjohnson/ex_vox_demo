defmodule ExVoxDemo.CaptureStore do
  @moduledoc """
  Saves audio and transcript files to disk with timestamps.
  Audio is saved BEFORE transcription so recordings survive API failures.
  """

  require Logger

  def captures_dir do
    Application.get_env(:ex_vox_demo, :captures_dir) ||
      Path.expand("~/captures/exvox")
  end

  def save_audio(binary, opts \\ []) do
    dir = captures_dir()
    File.mkdir_p!(dir)

    timestamp = opts[:timestamp] || timestamp_now()
    ext = opts[:ext] || "webm"
    filename = "#{timestamp}.#{ext}"
    path = Path.join(dir, filename)

    case File.write(path, binary) do
      :ok ->
        Logger.info("Audio saved: #{path} (#{byte_size(binary)} bytes)")
        {:ok, path, timestamp}

      {:error, reason} ->
        Logger.error("Failed to save audio: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def save_transcript(timestamp, text) do
    dir = captures_dir()
    path = Path.join(dir, "#{timestamp}.md")

    content = """
    ---
    captured: #{timestamp}
    source: exvox-desktop
    ---

    #{text}
    """

    case File.write(path, content) do
      :ok ->
        Logger.info("Transcript saved: #{path}")
        {:ok, path}

      {:error, reason} ->
        Logger.error("Failed to save transcript: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def save_cleaned_transcript(timestamp, raw_text, cleaned_text) do
    dir = captures_dir()
    path = Path.join(dir, "#{timestamp}.md")

    content = """
    ---
    captured: #{timestamp}
    source: exvox-desktop
    cleaned: true
    ---

    #{cleaned_text}

    ---
    **Raw transcript:**
    #{raw_text}
    """

    case File.write(path, content) do
      :ok ->
        Logger.info("Cleaned transcript saved: #{path}")
        {:ok, path}

      {:error, reason} ->
        Logger.error("Failed to save cleaned transcript: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp timestamp_now do
    {{y, mo, d}, {h, mi, s}} = :calendar.local_time()

    :io_lib.format("~4..0B-~2..0B-~2..0B_~2..0B-~2..0B-~2..0B", [y, mo, d, h, mi, s])
    |> IO.iodata_to_binary()
  end
end
