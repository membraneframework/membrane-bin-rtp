defmodule Membrane.Bin.RTP do
  use Membrane.Bin

  alias Membrane.Element
  alias Membrane.Bin
  alias Membrane.ParentSpec
  alias Membrane.Protocol.SDP
  alias Membrane.Element.RTP

  # TODO for now, every media stream has to have a mapping and only one mapping!
  # We don't know what we will have on entry here

  def_input_pad :input, demand_unit: :buffers, caps: :any, availability: :on_request

  def_output_pad :output, caps: :any, demand_unit: :buffers, availability: :on_request

  @impl true
  def handle_init(opts) do
    children = [ssrc_router: Bin.SSRCRouter]
    links = []

    spec = %ParentSpec{children: children, links: links}

    {{:ok, spec: spec}, :ignored}
  end

  @impl true
  def handle_pad_added({:dynamic, :input = pad_name, id}, _ctx, state) do
    # :erlang.make_ref()}
    parser_ref = {:parser, :rand.uniform(100_000)}

    children = [{parser_ref, RTP.Parser}]

    links = [link_bin_input(pad_name, id: id) |> to(parser_ref) |> to(:ssrc_router)]

    new_spec = %ParentSpec{children: children, links: links}

    {{:ok, spec: new_spec}, state}
  end

  def handle_pad_added(_, _ctx, state) do
    {:ok, state}
  end

  @impl true
  # TODO can I only return new elements and links?
  def handle_notification({:new_rtp_stream, ssrc, payload_type}, :ssrc_router, state) do
    IO.puts("New rtp stream (payload type: #{inspect(payload_type)}, ssrc: #{inspect(ssrc)})")
    depayloader = payload_type_to_depayloader(payload_type)

    # :erlang.make_ref()}
    rtp_session_name = {:rtp_session, :rand.uniform(100_000)}
    new_children = [{rtp_session_name, %Bin.RTPSession{depayloader: depayloader}}]

    new_links = [
      link(:ssrc_router) |> via_out(:output, pad: [ssrc: ssrc]) |> to(rtp_session_name)
    ]

    new_spec = %ParentSpec{children: new_children, links: new_links}
    {{:ok, spec: new_spec}, state}
  end

  alias Membrane.Element.RTP.H264
  defp payload_type_to_depayloader("H264"), do: RTP.H264.Depayloader
  defp payload_type_to_depayloader("MPA"), do: RTP.MPEGAudio.Depayloader
end
