defmodule DatingRoom.Matchmaker do
  require Logger
  use GenServer

  defmodule Match do
    defstruct room_id: ""
  end

  def start_link(opts \\ []),
   do: GenServer.start_link(__MODULE__, [], [name: __MODULE__] ++ opts)

  def join() do
    GenServer.cast(__MODULE__, {:join, self})
  end

  def init([]) do
    {:ok, []}
  end

  def handle_cast({:join, pid}, state) do
    state = [pid | state]
    |> Enum.filter(&Process.alive?/1)
    |> make_match
    {:noreply, state}
  end

  defp make_match([] = players), do: players
  defp make_match([_] = players), do: players
  defp make_match([p1, p2 | rest]) do
    room_id = :erlang.phash2({p1, p2, System.monotonic_time}) |> Integer.to_string
    for pid <- [p1, p2], do: send(pid, %Match{room_id: room_id})
    make_match(rest)
  end

end
