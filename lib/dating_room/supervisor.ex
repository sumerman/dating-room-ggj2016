defmodule DatingRoom.Supervisor do
  use Supervisor

  def start_link, do: Supervisor.start_link(__MODULE__, :ok)
  def init(:ok), do: supervise([], strategy: :one_for_one)
end
