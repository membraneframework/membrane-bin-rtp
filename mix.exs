defmodule Membrane.Bin.RTP.MixProject do
  use Mix.Project

  @version "0.1.0"
  @github_url "https://github.com/membraneframework/membrane-bin-rtp"

  def project do
    [
      app: :membrane_bin_rtp,
      version: @version,
      elixir: "~> 1.7",
      name: "Membrane Bin RTP",
      description: "Membrane Multimedia Framework (RTP bin)",
      package: package(),
      source_url: @github_url,
      docs: docs(),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_ref: "v#{@version}"
    ]
  end

  defp package do
    [
      maintainers: ["Membrane Team"],
      licenses: ["Apache 2.0"],
      links: %{
        "GitHub" => @github_url,
        "Membrane Framework Homepage" => "https://membraneframework.org"
      }
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:membrane_core, "~> 0.5.0"},
      {:membrane_element_rtp, "~> 0.3.0"},
      {:membrane_element_rtp_jitter_buffer, "~> 0.2.0"},
      {:membrane_protocol_sdp, "~> 0.1.0"},
      {:membrane_element_rtp_mpeguadio, "~> 0.3.0"},
      {:dialyxir, "~> 1.0.0-rc.7", only: [:dev], runtime: false},
      {:membrane_element_rtp_h264, "~> 0.2.0", only: [:test]},
      {:membrane_element_ffmpeg_h264, "~> 0.2.0", only: [:test]},
      {:membrane_element_pcap, github: "membraneframework/membrane-element-pcap", only: [:test]},
      {:csv, "~> 2.3", runtime: false}
    ]
  end
end
