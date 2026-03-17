defmodule Seki.MixProject do
  use Mix.Project

  {:ok, [{:application, :seki, props}]} = :file.consult("src/seki.app.src")
  @props Keyword.take(props, [:applications, :description, :env, :mod, :vsn])

  def project do
    [
      app: :seki,
      version: to_string(application()[:vsn]),
      language: :erlang,
      description: description(),
      package: package(),
      deps: deps()
    ]
  end

  def application, do: @props

  defp description do
    "Resilience library for the BEAM - circuit breaking, rate limiting, bulkheads, and retry"
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/Taure/seki"},
      files: ~w(src include rebar.config rebar.lock mix.exs README.md LICENSE.md)
    ]
  end

  defp deps do
    [
      {:telemetry, "~> 1.3"}
    ]
  end
end
