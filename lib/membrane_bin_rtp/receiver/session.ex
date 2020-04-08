defmodule Membrane.Bin.RTP.Receiver.Session do
  @moduledoc """
  This bin gets a parsed rtp stream on input and outputs raw media stream.
  Its responsibility is to depayload the rtp stream and compensate the
  jitter.
  """

  use Membrane.Bin

  alias Membrane.ParentSpec

  def_options depayloader: [type: :module],
              jitter: [type: :time, default: Membrane.Time.milliseconds(200)]

  def_input_pad :input, demand_unit: :buffers, caps: :any

  def_output_pad :output, caps: :any, demand_unit: :buffers

  @impl true
  def handle_init(opts) do
    children = [
      jitter_buffer: %Membrane.Element.RTP.JitterBuffer{latency: opts.jitter},
      depayloader: opts.depayloader
    ]

    links = [
      link_bin_input()
      |> to(:jitter_buffer)
      |> to(:depayloader)
      |> to_bin_output()
    ]

    spec = %ParentSpec{
      children: children,
      links: links
    }

    {{:ok, spec: spec}, %{}}
  end
end
