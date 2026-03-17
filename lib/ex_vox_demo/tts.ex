defmodule ExVoxDemo.TTS do
  @endpoint "https://api.openai.com/v1/audio/speech"
  @default_model "gpt-4o-mini-tts"
  @default_voice "alloy"
  @default_format "mp3"

  def synthesize(text, opts \\ []) when is_binary(text) do
    text = String.trim(text)

    cond do
      text == "" ->
        {:error, :empty_text}

      api_key() in [nil, ""] ->
        {:error, :missing_api_key}

      true ->
        body =
          %{
            "model" => Keyword.get(opts, :model, @default_model),
            "input" => text,
            "voice" => Keyword.get(opts, :voice, @default_voice),
            "format" => Keyword.get(opts, :format, @default_format)
          }
          |> maybe_put_speed(opts)

        headers = [{"authorization", "Bearer #{api_key()}"}]

        case Req.post(@endpoint, json: body, headers: headers) do
          {:ok, %{status: status, body: body}} when status in 200..299 ->
            {:ok, body}

          {:ok, %{status: status, body: body}} ->
            {:error, {:http_error, status, body}}

          {:error, error} ->
            {:error, error}
        end
    end
  end

  defp api_key, do: Application.get_env(:ex_vox, :api_key)

  defp maybe_put_speed(body, opts) do
    case Keyword.get(opts, :speed) do
      nil -> body
      speed -> Map.put(body, "speed", speed)
    end
  end
end
