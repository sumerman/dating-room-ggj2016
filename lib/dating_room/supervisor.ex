defmodule DatingRoom.Supervisor do
  use Supervisor

  def start_link(), do: Supervisor.start_link(__MODULE__, :ok)
  def init(:ok), do: Supervisor.init([Broker, DatingRoom.Matchmaker], strategy: :one_for_one)

end
