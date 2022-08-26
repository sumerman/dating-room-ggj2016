defmodule DatingRoom.Matchmaker do
  require Logger
  use GenServer

  defmodule Match do
    defstruct room_id: ""
  end

  def start_link(opts \\ []),
   do: GenServer.start_link(__MODULE__, [], [name: __MODULE__] ++ opts)

  def join(), do: GenServer.call(__MODULE__, {:join, self()})
  def leave() do
    GenServer.call(__MODULE__, {:leave, self()})
    flush_matches()
  end
  def queue_length(), do: GenServer.call(__MODULE__, :queue_length)

  def init([]), do: {:ok, []}

  def handle_call(:queue_length, _from, state) do
    {:reply, Enum.filter(state, &Process.alive?/1) |> length, state}
  end

  def handle_call({:join, pid}, from, state) do
    GenServer.reply(from, :ok)

    state = [pid | state]
    |> Enum.filter(&Process.alive?/1)
    |> make_match
    {:noreply, state}
  end

  def handle_call({:leave, pid}, _from, state) do
    state = Enum.filter(state, &(&1 != pid))
    {:reply, :ok, state}
  end

  defp make_match([] = players), do: players
  defp make_match([_] = players), do: players
  defp make_match([p1, p2 | rest]) do
    room_id = :erlang.phash2({p1, p2, System.monotonic_time}) |> Integer.to_string
    for pid <- [p1, p2], do: send(pid, %Match{room_id: room_id})
    make_match(rest)
  end

  defp flush_matches() do
    receive do
      %Match{} -> flush_matches()
    after 0 -> :ok
    end
  end

end
