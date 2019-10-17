defmodule Membrane.Bin.RTPSession do
  use Membrane.Bin

  alias Membrane.Element.RTP.Parser
  alias Membrane.ParentSpec

  def_options depayloader: [type: :module]

  def_input_pad :input, demand_unit: :buffers, caps: :any

  def_output_pad :output, caps: :any, demand_unit: :buffers

  @impl true
  def handle_init(opts) do
    children = [
      parser: Parser,
      jitter_buffer: %Membrane.Element.RTP.JitterBuffer{slot_count: 10},
      depayloader: opts.depayloader
    ]

    links = %{
      {Bin.itself(), :input} => {:parser, :input, []},
      {:parser, :output} => {:jitter_buffer, :input, []},
      {:jitter_buffer, :output} => {:depayloader, :input},
      {:depayloader, :output} => {Bin.itself(), :output, []}
    }

    spec = %ParentSpec{
      children: children,
      links: links
    }

    {{:ok, spec: spec}, %{}}
  end
end
