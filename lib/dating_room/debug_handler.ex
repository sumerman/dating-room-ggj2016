defmodule DatingRoom.DebugHandler do

  def init(_type, req, []), do: {:ok, req, :no_state}

  def handle(request, state) do
    {:ok, reply} = :cowboy_req.reply(
      # status code
      200,
      # headers
      [ {"content-type", "application/json"} ],
      # body of reply.
      Poison.encode!(status) <> "\n",
      # original request
      request
    )

    {:ok, reply, state}
  end

  def terminate(_reason, _request, _state), do: :ok

  alias DatingRoom.Matchmaker

  defp status do
    %{
      matchmaker_queue_size: Matchmaker.queue_length
    }
  end

end
