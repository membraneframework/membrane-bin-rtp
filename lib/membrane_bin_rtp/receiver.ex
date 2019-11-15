defmodule Membrane.Bin.RTP.Receiver do
  @doc """
  This bin can have multiple inputs. On each it can consume one or many
  rtp streams.

  Every stream is parsed and then (based on ssrc field) an
  appropriate rtp session is initiated. It notifies its parent about each new
  stream with a notification of the format `{:new_rtp_stream, ssrc, payload_type}`.
  Parent should then connect to RTP bin dynamic output pad instance that will
  have an id == `ssrc`.
  """
  use Membrane.Bin

  alias Membrane.Bin.RTP.Receiver
  alias Membrane.ParentSpec
  alias Membrane.Element.RTP

  def_options fmt_mapping: [
                spec: %{},
                default: %{},
                description: "Mapping of the custom payload types (form fmt > 95)"
              ],
              pt_to_depayloader: [
                spec: (String.t() -> module()),
                default: &__MODULE__.payload_type_to_depayloader/1,
                description: "Mapping from payload type to a depayloader module"
              ]

  def_input_pad :input, demand_unit: :buffers, caps: :any, availability: :on_request

  def_output_pad :output, caps: :any, demand_unit: :buffers, availability: :on_request

  defmodule State do
    @moduledoc false

    defstruct ssrc_pt_mapping: %{}, depayloader_mapper: nil
  end

  @impl true
  def handle_init(%{fmt_mapping: fmt_map, pt_to_depayloader: d_mapper}) do
    children = [ssrc_router: %Receiver.SSRCRouter{fmt_mapping: fmt_map}]
    links = []

    spec = %ParentSpec{children: children, links: links}

    {{:ok, spec: spec}, %State{depayloader_mapper: d_mapper}}
  end

  @impl true
  def handle_pad_added(Pad.ref(:input, _id) = pad, _ctx, state) do
    parser_ref = {:parser, make_ref()}

    children = [{parser_ref, RTP.Parser}]

    links = [link_bin_input(pad) |> to(parser_ref) |> to(:ssrc_router)]

    new_spec = %ParentSpec{children: children, links: links}

    {{:ok, spec: new_spec}, state}
  end

  @impl true
  def handle_pad_added(
        Pad.ref(:output, ssrc) = pad,
        _ctx,
        %State{ssrc_pt_mapping: ssrc_pt_mapping} = state
      ) do
    depayloader =
      ssrc_pt_mapping
      |> Map.get(ssrc)
      |> state.depayloader_mapper.()

    rtp_session_name = {:rtp_session, make_ref()}
    new_children = [{rtp_session_name, %Receiver.Session{depayloader: depayloader}}]

    new_links = [
      link(:ssrc_router)
      |> via_out(Pad.ref(:output, ssrc))
      |> to(rtp_session_name)
      |> to_bin_output(pad)
    ]

    new_spec = %ParentSpec{children: new_children, links: new_links}
    {{:ok, spec: new_spec}, state}
  end

  @impl true
  def handle_notification({:new_rtp_stream, ssrc, payload_type}, :ssrc_router, state) do
    %State{ssrc_pt_mapping: ssrc_pt_mapping} = state

    new_ssrc_pt_mapping = ssrc_pt_mapping |> Map.put(ssrc, payload_type)

    {{:ok, notify: {:new_rtp_stream, ssrc, payload_type}},
     %{state | ssrc_pt_mapping: new_ssrc_pt_mapping}}
  end

  @spec payload_type_to_depayloader(Receiver.SSRCRouter.payload_type()) :: module()
  def payload_type_to_depayloader("H264"), do: RTP.H264.Depayloader
  def payload_type_to_depayloader("MPA"), do: RTP.MPEGAudio.Depayloader
end
