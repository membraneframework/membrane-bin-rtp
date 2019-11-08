defmodule Membrane.Bin.RTPSession do
  use Membrane.Bin

  alias Membrane.ParentSpec

  def_options depayloader: [type: :module]

  def_input_pad :input, demand_unit: :buffers, caps: :any

  def_output_pad :output, caps: :any, demand_unit: :buffers

  @impl true
  def handle_init(opts) do
    children = [
      jitter_buffer: %Membrane.Element.RTP.JitterBuffer{slot_count: 10},
      depayloader: opts.depayloader
    ]

    links = [
      link_bin_input() |> to(:jitter_buffer) |> to(:depayloader) |> to_bin_output()
    ]

    spec = %ParentSpec{
      children: children,
      links: links
    }

    {{:ok, spec: spec}, %{}}
  end
end
