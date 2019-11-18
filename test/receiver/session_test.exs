defmodule Membrane.Bin.RTP.Receiver.SessionTest do
  use ExUnit.Case
  alias Membrane.Testing

  alias Membrane.Bin.RTP.Receiver
  alias Membrane.Element.RTP
  alias Membrane.Element.RTP.H264

  import Testing.Assertions

  @pcap_file "test/demo.pcap"
  @frames_count 1038

  defmodule FrameCounter do
    use Membrane.Sink

    def_input_pad :input, demand_unit: :buffers, caps: :any

    @impl true
    def handle_init(_), do: {:ok, %{counter: 0}}

    @impl true
    def handle_prepared_to_playing(_ctx, state),
      do: {{:ok, demand: :input}, state}

    @impl true
    def handle_write(_pad, _buff, _context, %{counter: c}),
      do: {{:ok, demand: :input}, %{counter: c + 1}}

    @impl true
    def handle_end_of_stream(_pad, _ctx, %{counter: c} = state),
      do: {{:ok, notify: {:frame_count, c}}, state}
  end

  test "RTP stream passes through bin properly" do
    opts = %Testing.Pipeline.Options{
      elements: [
        pcap: %Membrane.Element.Pcap.Source{path: @pcap_file},
        rtp_parser: RTP.Parser,
        rtp: %Receiver.Session{depayloader: H264.Depayloader},
        video_parser: %Membrane.Element.FFmpeg.H264.Parser{framerate: {30, 1}},
        frame_counter: FrameCounter
      ]
    }

    {:ok, pipeline} = Testing.Pipeline.start_link(opts)

    Testing.Pipeline.play(pipeline)

    assert_pipeline_notified(pipeline, :frame_counter, {:frame_count, count})
    assert count == @frames_count
  end
end
