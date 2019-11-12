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
      # TODO replace with proper gihtub refs
      {:membrane_core, path: "~/membrane-core", override: true},
      {:membrane_element_rtp, path: "/Users/dominikstanaszek/membrane-element-rtp"},
      {:membrane_element_rtp_jitter_buffer, github: "membraneframework/membrane-element-rtp-jitter-buffer"},
      {:membrane_protocol_sdp, github: "membraneframework/membrane-protocol-sdp"},
      {:membrane_element_rtp_mpeguadio, github: "membraneframework/membrane-element-rtp-mpegaudio"},
      {:membrane_element_sdl, github: "membraneframework/membrane-element-sdl"},
      {:membrane_element_file, github: "membraneframework/membrane-element-file"},
      {:dialyxir, "~> 1.0.0-rc.7", only: [:dev], runtime: false},
      {:membrane_element_rtp_h264, github: "membraneframework/membrane-element-rtp-h264", only: [:test]},
      {:membrane_element_ffmpeg_h264, "~> 0.1", only: [:test]},
      {:membrane_element_pcap, github: "membraneframework/membrane-element-pcap", only: [:test]}
    ]
  end
end
