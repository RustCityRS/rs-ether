defmodule RsEther.MixProject do
  use Mix.Project

  def project do
    [
      app: :rs_ether,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {RsEther.Application, []}
    ]
  end

  defp deps do
    [
      {:ecto_sql, "~> 3.10"},
      {:postgrex, ">= 0.0.0"},
      {:libcluster, "~> 3.3"},
      {:burrito, "~> 1.0", runtime: false}
    ]
  end

  # The single `rs_ether` release backs both distribution targets:
  #   * Docker image     → `mix release rs_ether`              (plain :assemble)
  #   * Native binaries  → `BURRITO_BUILD=1 mix release rs_ether` (Burrito wrap)
  # Gating the Burrito step on the env var keeps the Docker build from needing
  # Zig and keeps both artifacts byte-for-byte the same OTP release.
  defp releases do
    [
      rs_ether: [
        include_executables_for: [:unix, :windows],
        applications: [runtime_tools: :permanent],
        steps: release_steps(),
        burrito: [
          targets: [
            linux_x86_64: [os: :linux, cpu: :x86_64],
            linux_arm64: [os: :linux, cpu: :aarch64],
            macos_x86_64: [os: :darwin, cpu: :x86_64],
            macos_arm64: [os: :darwin, cpu: :aarch64],
            windows_x86_64: [os: :windows, cpu: :x86_64]
          ]
        ]
      ]
    ]
  end

  defp release_steps do
    if System.get_env("BURRITO_BUILD") == "1" do
      [:assemble, &Burrito.wrap/1]
    else
      [:assemble]
    end
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"]
    ]
  end
end
