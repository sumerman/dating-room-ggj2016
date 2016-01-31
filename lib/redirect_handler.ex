defmodule RedirectHandler do
  def init(_type, req, {:path, path}), do: {:ok, req, %{path: path}}

  def handle(request, state) do
    {:ok, reply} = :cowboy_req.reply(
      # status code
      302,
      # headers
      [ {"location", state.path} ],
      # body of reply.
      "",
      # original request
      request
    )
    {:ok, reply, state}
  end

  def terminate(_reason, _request, _state), do: :ok

end
