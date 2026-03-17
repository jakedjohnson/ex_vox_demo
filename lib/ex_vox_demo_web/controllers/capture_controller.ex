defmodule ExVoxDemoWeb.CaptureController do
  use ExVoxDemoWeb, :controller

  alias ExVoxDemo.CaptureStore

  def audio(conn, %{"filename" => filename}) do
    path = Path.join(CaptureStore.captures_dir(), filename)

    if File.exists?(path) and String.ends_with?(filename, ".webm") do
      conn
      |> put_resp_content_type("audio/webm")
      |> send_file(200, path)
    else
      conn
      |> put_status(404)
      |> text("Not found")
    end
  end
end
