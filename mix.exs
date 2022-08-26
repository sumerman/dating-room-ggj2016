defmodule DatingRoom.Mixfile do
  use Mix.Project

  def project do
    [app: :dating_room,
     version: "0.0.1",
     elixir: "~> 1.9",
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     deps: deps()]
  end

  def application() do
    [
      applications: [:logger, :ranch, :cowboy, :exredis, :crypto, :poison],
      mod: {DatingRoom, []}
    ]
  end

  defp deps() do
    [
      {:cowboy, "1.0.4", manager: :rebar3},
      {:exredis, "~> 0.3.0"},
      {:poison, "~> 5.0"}
    ]
  end
end
