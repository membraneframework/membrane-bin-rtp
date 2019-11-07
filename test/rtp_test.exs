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
    def handle_process(pad, buffer, _ctx, state) do
      # IO.inspect Membrane.Element.RTP.PacketParser.parse_packet(buffer.payload)
      {{:ok, buffer: {:output, buffer}}, state}
    end

    @impl true
    def handle_demand(pad, size, unit, _ctx, state) do
      {{:ok, demand: {:input, size}}, state}
    end
  end

  test "" do
    opts = %Testing.Pipeline.Options{
      elements: [
        pcap: %Membrane.Element.Pcap.Source{path: "test/demo_rtp.pcap"},
        inspect: Inspect,
        rtp: Bin.RTP,
        dumper: Testing.Sink
      ]
    }

    {:ok, pipeline} = Testing.Pipeline.start_link(opts)

    Testing.Pipeline.play(pipeline)

    assert_sink_buffer(pipeline, :dumper, _)
  end
end
