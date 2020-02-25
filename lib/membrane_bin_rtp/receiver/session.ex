defmodule Membrane.Bin.RTP.Receiver.Session do
  @moduledoc """
  This bin gets a parsed rtp stream on input and outputs raw media stream.
  Its responsibility is to depayload the rtp stream and compensate the
  jitter.
  """

  use Membrane.Bin

  alias Membrane.Bin.RTP.PayloadType
  alias Membrane.Element.RTP
  alias Membrane.ParentSpec

  def_options depayloader: [type: :module], payload_type: [spec: PayloadType.t()]

  def_input_pad :input, demand_unit: :buffers, caps: :any

  def_input_pad :rtcp, demand_unit: :buffers, caps: :any

  def_output_pad :output, caps: :any, demand_unit: :buffers

  @impl true
  def handle_init(opts) do
    children = [
      parser: RTP.Parser,
      jitter_buffer: %Membrane.Element.RTP.JitterBuffer{
        clockrate: opts.payload_type.clockrate,
        slot_count: 10
      },
      depayloader: opts.depayloader
    ]

    links = [
      link_bin_input()
      |> to(:parser)
      |> to(:jitter_buffer)
      |> to(:depayloader)
      |> to_bin_output(),
      link_bin_input(:rtcp)
      |> via_in(:rtcp)
      |> to(:jitter_buffer)
    ]

    spec = %ParentSpec{
      children: children,
      links: links
    }

    {{:ok, spec: spec}, %{}}
  end
end
