defmodule DatingRoom.Mixfile do
  use Mix.Project

  def project do
    [app: :dating_room,
     version: "0.0.1",
     elixir: "~> 1.2",
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     deps: deps]
  end

  def application do
    [
      applications: [:logger, :ranch, :cowboy],
      mod: {DatingRoom, []}
    ]
  end

  defp deps do
    [
      {:cowboy, "1.0.4"},
      {:poison, "~> 2.0"}
    ]
  end
end
