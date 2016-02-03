defmodule DatingRoom.Supervisor do
  use Supervisor

  def start_link, do: Supervisor.start_link(__MODULE__, :ok)
  def init(:ok), do: supervise([broker_spec, matchmaker_spec], strategy: :one_for_one)

  defp broker_spec, do: worker(Broker, [])
  defp matchmaker_spec, do: worker(DatingRoom.Matchmaker, [])
end
