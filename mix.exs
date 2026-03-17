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
      deps: deps(),
      docs: docs()
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
      {:telemetry, "~> 1.3"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "LICENSE.md"],
      source_url: "https://github.com/Taure/seki",
      groups_for_modules: [
        "Core API": [:seki, :seki_breaker, :seki_bulkhead, :seki_retry, :seki_deadline],
        "Rate Limiting": [
          :seki_algorithm,
          :seki_backend,
          :seki_backend_ets,
          :seki_backend_pg,
          :seki_pg_gossip
        ],
        "Advanced Patterns": [:seki_adaptive, :seki_shed, :seki_hedge, :seki_health],
        Instrumentation: [:seki_otel]
      ]
    ]
  end
end
