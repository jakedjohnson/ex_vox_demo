defmodule ExVoxDemo.NounCleanup do
  @moduledoc """
  Second-pass proper noun correction using OpenAI chat API.

  Reads proper nouns from a markdown file. Configure the path via:

    - Environment variable: `PROPER_NOUNS_PATH`
    - App config: `config :ex_vox_demo, proper_nouns_path: "/path/to/proper-nouns.md"`
    - Dev secrets: `config/dev.secrets.exs` (gitignored, per-machine)

  If no path is configured, the cleanup step is skipped and the raw
  transcript is returned as-is.
  """

  require Logger

  @api_url "https://api.openai.com/v1/chat/completions"
  @model "gpt-4o-mini"

  def cleanup(raw_transcript) do
    case resolve_nouns_path() do
      nil ->
        Logger.info("No proper_nouns_path configured — skipping cleanup. " <>
          "Set PROPER_NOUNS_PATH or add to config/dev.secrets.exs")
        {:ok, raw_transcript}

      nouns_path ->
        case File.read(nouns_path) do
          {:ok, nouns_doc} ->
            call_api(raw_transcript, nouns_doc)

          {:error, reason} ->
            Logger.warning("Proper nouns file not found at #{nouns_path}: #{inspect(reason)}")
            {:error, :nouns_file_missing}
        end
    end
  end

  defp resolve_nouns_path do
    Application.get_env(:ex_vox_demo, :proper_nouns_path) ||
      System.get_env("PROPER_NOUNS_PATH")
  end

  defp call_api(transcript, nouns_doc) do
    api_key = Application.get_env(:ex_vox, :api_key)

    if is_nil(api_key) or api_key == "" do
      {:error, :missing_api_key}
    else
      body =
        Jason.encode!(%{
          model: @model,
          messages: [
            %{
              role: "system",
              content: """
              You are a transcript cleanup assistant. Fix proper nouns, names, and technical terms \
              using the reference document below. Return ONLY the corrected transcript — no \
              explanations, no preamble, no wrapping. Preserve the original structure and tone exactly. \
              Only fix names and proper nouns that are clearly garbled versions of entries in the reference.

              ## Proper Noun Reference
              #{nouns_doc}
              """
            },
            %{
              role: "user",
              content: transcript
            }
          ],
          temperature: 0.1,
          max_tokens: 4096
        })

      case Req.post(@api_url,
             body: body,
             headers: [
               {"authorization", "Bearer #{api_key}"},
               {"content-type", "application/json"}
             ],
             receive_timeout: 30_000
           ) do
        {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => cleaned}} | _]}}} ->
          {:ok, String.trim(cleaned)}

        {:ok, %{status: status, body: body}} ->
          Logger.error("Noun cleanup API error #{status}: #{inspect(body)}")
          {:error, {:api_error, status}}

        {:error, reason} ->
          Logger.error("Noun cleanup request failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end
end
