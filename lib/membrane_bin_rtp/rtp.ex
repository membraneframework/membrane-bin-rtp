defmodule Membrane.Bin.RTP do
  use Membrane.Bin

  alias Membrane.Bin
  alias Membrane.ParentSpec
  alias Membrane.Element.RTP

  def_options fmt_mapping: [type: :map, default: %{}]

  def_input_pad :input, demand_unit: :buffers, caps: :any, availability: :on_request

  def_output_pad :output, caps: :any, demand_unit: :buffers, availability: :on_request

  defmodule State do
    defstruct ssrc_pt: %{}
  end

  @impl true
  def handle_init(%{fmt_mapping: fmt_map}) do
    children = [ssrc_router: %Bin.SSRCRouter{fmt_mapping: fmt_map}]
    links = []

    spec = %ParentSpec{children: children, links: links}

    {{:ok, spec: spec}, %State{}}
  end

  @impl true
  def handle_pad_added(Pad.ref(:input, _id) = pad, _ctx, state) do
    parser_ref = {:parser, :erlang.make_ref()}

    children = [{parser_ref, RTP.Parser}]

    links = [link_bin_input(pad) |> to(parser_ref) |> to(:ssrc_router)]

    new_spec = %ParentSpec{children: children, links: links}

    {{:ok, spec: new_spec}, state}
  end

  def handle_pad_added(Pad.ref(:output, ssrc) = pad, _ctx, %State{ssrc_pt: ssrc_pt} = state) do
    depayloader =
      ssrc_pt
      |> Map.get(ssrc)
      |> payload_type_to_depayloader()

    rtp_session_name = {:rtp_session, :erlang.make_ref()}
    new_children = [{rtp_session_name, %Bin.RTPSession{depayloader: depayloader}}]

    new_links = [
      link(:ssrc_router)
      |> via_out(:output, options: [ssrc: ssrc])
      |> to(rtp_session_name)
      |> to_bin_output(pad)
    ]

    new_spec = %ParentSpec{children: new_children, links: new_links}
    {{:ok, spec: new_spec}, state}
  end

  @impl true
  def handle_notification({:new_rtp_stream, ssrc, payload_type}, :ssrc_router, state) do
    %State{ssrc_pt: ssrc_pt} = state

    new_ssrc_pt = ssrc_pt |> Map.put(ssrc, payload_type)

    {{:ok, notify: {:new_rtp_stream, ssrc, payload_type}}, %{state | ssrc_pt: new_ssrc_pt}}
  end

  defp payload_type_to_depayloader("H264"), do: RTP.H264.Depayloader
  defp payload_type_to_depayloader("MPA"), do: RTP.MPEGAudio.Depayloader
end
