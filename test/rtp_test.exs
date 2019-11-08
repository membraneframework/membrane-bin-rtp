defmodule Membrane.Test.RTP do
  use ExUnit.Case

  alias Membrane.Bin
  alias Membrane.Testing

  @timeout 200

  @pcap_file "test/demo_rtp.pcap"

  @audio_stream %{ssrc: 439_017_412, frames_n: 20}
  @video_stream %{ssrc: 670_572_639, frames_n: 287}

  @fmt_mapping %{96 => "H264", 127 => "MPA"}

  defmodule TestSink do
    use Membrane.Sink

    def_input_pad :input, demand_unit: :buffers, caps: :any

    def_options test_pid: [type: :pid], name: [type: :any]

    @impl true
    def handle_init(state), do: {:ok, state}

    @impl true
    def handle_prepared_to_playing(_ctx, state) do
      {{:ok, demand: :input}, state}
    end

    @impl true
    def handle_write(_pad, buffer, _ctx, state) do
      send(state.test_pid, {state.name, buffer})
      {{:ok, demand: :input}, state}
    end
  end

  defmodule DynamicPipeline do
    use Membrane.Pipeline

    @impl true
    def handle_init(%{test_pid: test_pid, pcap_file: pcap_file, fmt_mapping: fmt_mapping}) do
      spec = %ParentSpec{
        children: [
          pcap: %Membrane.Element.Pcap.Source{path: pcap_file},
          rtp: %Bin.RTP{fmt_mapping: fmt_mapping}
        ],
        links: [link(:pcap) |> to(:rtp)]
      }

      {{:ok, spec: spec}, test_pid}
    end

    @impl true
    def handle_notification({:new_rtp_stream, ssrc, _pt}, :rtp, state) do
      spec = %ParentSpec{
        children: [
          {ssrc, %TestSink{test_pid: state, name: ssrc}}
        ],
        links: [
          link(:rtp) |> via_out(Pad.ref(:output, ssrc)) |> to(ssrc)
        ]
      }

      {{:ok, spec: spec}, state}
    end

    def handle_notification(_, _, state) do
      {:ok, state}
    end
  end

  test "RTP streams passes through RTP bin properly" do
    {:ok, pipeline} =
      DynamicPipeline.start_link(%{
        test_pid: self(),
        pcap_file: @pcap_file,
        fmt_mapping: @fmt_mapping
      })

    Testing.Pipeline.play(pipeline)

    for stream_opts <- [@audio_stream, @video_stream] do
      assert stream_opts.frames_n == get_buffers(stream_opts.ssrc)
    end
  end

  defp get_buffers(n \\ 0, ssrc) do
    receive do
      {^ssrc, %Membrane.Buffer{}} ->
        get_buffers(n + 1, ssrc)
    after
      @timeout ->
        n
    end
  end
end
