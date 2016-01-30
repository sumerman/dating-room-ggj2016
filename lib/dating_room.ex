defmodule DatingRoom do
  def start(_type, _args) do
    dispatch = :cowboy_router.compile([{:_, routes}])
    {:ok, _} = :cowboy.start_http(:http, 100, [port: port], [env: [dispatch: dispatch]])
  end

  def port, do: Application.get_env(:dating_room, :http_port)
  def routes do
    [
      # {"/static/[...]", :cowboy_static, {:priv_dir,  :cowboy_elixir_example, "static_files"}},
      {"/websocket", DatingRoom.WebsocketHandler, []}
    ]
  end
end
