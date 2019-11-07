defmodule MembraneBinRtp.MixProject do
  use Mix.Project

  def project do
    [
      app: :membrane_bin_rtp,
      version: "0.1.0",
      elixir: "~> 1.7",
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

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"},
      {:membrane_core, path: "~/membrane-core", override: true},
      {:membrane_element_rtp, path: "/Users/dominikstanaszek/membrane-element-rtp"},
      {:membrane_element_rtp_jitter_buffer, path: "~/membrane-element-rtp-jitter-buffer"},
      {:membrane_protocol_sdp, github: "membraneframework/membrane-protocol-sdp"},
      {:membrane_element_rtp_h264,
       git: "https://github.com/membraneframework/membrane-element-rtp-h264", only: [:test]},
      {:membrane_element_ffmpeg_h264, "~> 0.1", only: [:test]},
      {:membrane_element_pcap,
       path: "/Users/dominikstanaszek/membrane-element-pcap", only: [:test]},
      {:membrane_element_udp, github: "membraneframework/membrane-element-udp"},
      {:membrane_element_rtp_mpeguadio,
       github: "membraneframework/membrane-element-rtp-mpegaudio"}
    ]
  end
end
