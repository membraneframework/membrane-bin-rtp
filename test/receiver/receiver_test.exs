defmodule Membrane.Bin.RTP.Receiver.ReceiverTest do
  use ExUnit.Case

  alias Membrane.{Bin, Buffer}
  alias Membrane.Bin.RTP.PayloadType
  alias Membrane.Element.RTP.{RTCP, RTCP}
  alias Membrane.Testing

  @timeout 2000

  @rtp_pcap_file "test/demo_rtp.pcap"
  @rtcp_pcap_file "test/demo_rtcp.pcap"

  @demo_rtcp_ssrc 2_136
  @audio_ssrc 439_017_412
  @video_ssrc 670_572_639
  @audio_stream %{ssrc: @audio_ssrc, frames_n: 20}
  @video_stream %{ssrc: @video_ssrc, frames_n: 287}

  @fmt_mapping %{
    96 => %PayloadType{name: "H264", mediatype: "V", clockrate: 90000},
    127 => %PayloadType{name: "MPA", mediatype: "A", clockrate: 90000}
  }

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
      # IO.inspect({state.name, "is writing", buffer})
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
          rtp: %Bin.RTP.Receiver{fmt_mapping: fmt_mapping}
        ],
        links: [
          link(:pcap)
          |> to(:rtp)
        ]
      }

      {{:ok, spec: spec}, test_pid}
    end

    @impl true
    def handle_notification({:new_rtp_stream, ssrc, _pt}, :rtp, state) do
      spec = %ParentSpec{
        children: [
          {{:rtp, ssrc}, %TestSink{test_pid: state, name: {:rtp, ssrc}}},
          {{:rtcp, ssrc}, %TestSink{test_pid: state, name: {:rtcp, ssrc}}}
        ],
        links: [
          link(:rtp)
          |> via_out(Pad.ref(:rtp, ssrc))
          |> to({:rtp, ssrc}),
          link(:rtp)
          |> via_out(Pad.ref(:rtcp, ssrc))
          |> to({:rtcp, ssrc})
        ]
      }

      {{:ok, spec: spec}, state}
    end

    @impl true
    def handle_notification({:closed_rt_stream, ssrc} = msg, :rtp, state) do
      send(state, msg)
      {{:ok, remove_child: {:rtp, ssrc}}, state}
    end

    @impl true
    def handle_notification(msg, :rtp, state) do
      send(state, msg)
      {:ok, state}
    end
  end

  test "RTP streams passes through RTP bin properly" do
    {:ok, pipeline} =
      DynamicPipeline.start_link(%{
        test_pid: self(),
        pcap_file: @rtp_pcap_file,
        fmt_mapping: @fmt_mapping
      })

    Testing.Pipeline.play(pipeline)

    for stream_opts <- [@audio_stream, @video_stream] do
      assert stream_opts.frames_n == get_buffers_count({:rtp, stream_opts.ssrc})
    end
  end

  describe "RTCP" do
    setup do
      {:ok, pipeline} =
        DynamicPipeline.start_link(%{
          test_pid: self(),
          pcap_file: @rtcp_pcap_file,
          fmt_mapping: @fmt_mapping
        })

      Testing.Pipeline.play(pipeline)

      %{pipeline: pipeline}
    end

    test "compound packets result in a notification" do
      for _ <- 1..3, do: assert_receive({:rtcp, _})
    end

    test "Bye results in the stream ending" do
      assert_receive {:closed_rtp_stream, _, nil}
    end

    test "notifies of received sender reports", %{pipeline: pipeline} do
      assert_receive({:rtcp, %RTCP.Report{sender_info: %{}}})
    end
  end

  test "Controller generates and sends receiver reports" do
    {:ok, pipeline} =
      DynamicPipeline.start_link(%{
        test_pid: self(),
        pcap_file: @rtp_pcap_file,
        fmt_mapping: @fmt_mapping
      })

    Testing.Pipeline.play(pipeline)

    %{pipeline: pipeline}

    assert %Buffer{payload: binary_packet} = get_buffer({:rtcp, @video_ssrc}, 1000)
  end

  test "RTCP SDES CNAME result in a notification with the relevant SSRC" do
    {:ok, pipeline} =
      DynamicPipeline.start_link(%{
        test_pid: self(),
        pcap_file: @rtcp_pcap_file,
        fmt_mapping: @fmt_mapping
      })

    Testing.Pipeline.play(pipeline)
    assert_receive {:named_rtp_stream, @demo_rtcp_ssrc, _}
  end

  defp get_buffers_count(ssrc), do: length(get_buffers(ssrc))
  defp get_buffers(ssrc, timeout \\ @timeout), do: Enum.reverse(get_buffers(ssrc, [], timeout))

  defp get_buffers(ssrc, acc, timeout) do
    receive do
      {^ssrc, %Buffer{} = buffer} ->
        get_buffers(ssrc, [buffer | acc], timeout)
    after
      timeout -> acc
    end
  end

  defp get_buffer(ssrc, timeout) do
    receive do
      {^ssrc, %Buffer{} = buffer} -> buffer
    after
      timeout -> nil
    end
  end
end
