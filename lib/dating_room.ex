defmodule DatingRoom do
  def start(_type, _args) do
    dispatch = :cowboy_router.compile([{:_, routes()}])
    {:ok, _} = :cowboy.start_http(:http, 100, [port: port()], [env: [dispatch: dispatch]])
    DatingRoom.Supervisor.start_link()
  end

  def port() do
    port = Application.get_env(:dating_room, :http_port)
    case port do
      int when is_integer(int) -> port
      str when is_binary(str) -> String.to_integer(str)
    end
  end

  def routes() do
    [
      {"/", RedirectHandler, {:path, "./game/index.html"}},
      {"/game/[...]", :cowboy_static, {:priv_dir,  :dating_room, "game/TDG_Alpha"}},
      {"/websocket", DatingRoom.WebsocketHandler, []},
      {"/status", DatingRoom.DebugHandler, []}
    ]
  end
end
