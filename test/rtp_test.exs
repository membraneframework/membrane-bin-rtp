defmodule Membrane.Test.RTP do
  use ExUnit.Case

  alias Membrane.Bin
  alias Membrane.Testing

  import Membrane.Testing.Assertions

  defmodule Inspect do
    use Membrane.Filter

    def_input_pad :input, demand_unit: :buffers, caps: :any

    def_output_pad :output, caps: :any

    @impl true
    def handle_init(_) do
      {:ok, %{}}
    end

    defp update_seq(ssrc, seq, state) do
      case Map.get(state, ssrc) do
        %{min: mininimum, max: maximum} ->
          Map.put(state, ssrc, %{min: min(mininimum, seq), max: max(maximum, seq)})

        nil ->
          state
          |> Map.put(ssrc, %{min: seq, max: seq})
      end
    end

    @impl true
    def handle_process(pad, buffer, _ctx, state) do
      # {:ok, packet} = Membrane.Element.RTP.PacketParser.parse_packet(buffer.payload)

      # seq = packet.header.sequence_number
      # ssrc = packet.header.ssrc
      IO.puts("inspect saw: #{inspect(buffer)}")

      # new_state = update_seq(ssrc, seq, state)
      # update_seq(ssrc, seq, state)
      new_state = state

      {{:ok, buffer: {:output, buffer}}, new_state}
    end

    @impl true
    def handle_demand(pad, size, unit, _ctx, state) do
      {{:ok, demand: {:input, size}}, state}
    end
  end

  # test "" do
  #  import Membrane.ParentSpec

  #  opts = %Testing.Pipeline.Options{
  #    elements: [
  #      pcap: %Membrane.Element.Pcap.Source{path: "test/demo_rtp.pcap"},
  #      inspect: Inspect,
  #      rtp: Bin.RTP,
  #      dumper1: Testing.Sink,
  #      dumper2: Testing.Sink
  #    ],
  #    links: [
  #      link(:pcap) |> to(:inspect) |> to(:rtp),
  #      link(:rtp) |> to(:dumper1),
  #      link(:rtp) |> to(:dumper2)
  #    ]
  #  }

  #  {:ok, pipeline} = Testing.Pipeline.start_link(opts)

  #  Testing.Pipeline.play(pipeline)
  #  Process.sleep(2000)

  #  # TODO properly test
  #  assert_sink_buffer(pipeline, :dumper1, data)
  #  data |> IO.inspect()
  # end

  defmodule DynamicPipeline do
    use Membrane.Pipeline

    @impl true
    def handle_init(_) do
      spec = %ParentSpec{
        children: [
          pcap: %Membrane.Element.Pcap.Source{path: "test/demo_rtp.pcap"},
          rtp: Bin.RTP
        ],
        links: [link(:pcap) |> to(:rtp)]
      }

      {{:ok, spec: spec}, :no}
    end

    @impl true
    def handle_notification({:new_rtp_stream, ssrc, pt}, :rtp, state) do
      IO.puts("Pipeline got ")
      sink_name = String.to_atom(pt)
      inspect_name = String.to_atom("inspect" <> pt)

      spec = %ParentSpec{
        children: [
          {inspect_name, Inspect},
          {sink_name, %Membrane.Element.File.Sink{location: pt <> "_file.h264"}}
        ],
        links: [
          link(:rtp) |> via_out(Pad.ref(:output, ssrc)) |> to(inspect_name) |> to(sink_name)
        ]
      }

      {{:ok, spec: spec}, state}
    end

    def handle_notification(_, _, state) do
      {:ok, state}
    end
  end

  test "jdlak" do
    import Membrane.ParentSpec

    {:ok, pipeline} = DynamicPipeline.start_link(:ignored)

    Testing.Pipeline.play(pipeline)
    Process.sleep(5000)
  end
end
