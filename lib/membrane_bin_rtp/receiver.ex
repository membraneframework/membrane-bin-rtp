defmodule Membrane.Bin.RTP.Receiver do
  @doc """
  A bin consuming one or more RTP streams on each input and outputting a stream from one ssrc on each output

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
                spec: %{integer => String.t()},
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

    defstruct fmt_mapping: %{}, ssrc_pt_mapping: %{}, pt_to_depayloader: nil, parsers_by_pads: %{}
  end

  @impl true
  def handle_init(%{fmt_mapping: fmt_map, pt_to_depayloader: d_mapper}) do
    children = [ssrc_router: Receiver.SSRCRouter]
    links = []

    spec = %ParentSpec{children: children, links: links}

    {{:ok, spec: spec}, %State{fmt_mapping: fmt_map, pt_to_depayloader: d_mapper}}
  end

  @impl true
  def handle_pad_added(Pad.ref(:input, _id) = pad, _ctx, state) do
    parser_ref = {:parser, make_ref()}

    children = [{parser_ref, RTP.Parser}]

    links = [link_bin_input(pad) |> to(parser_ref) |> to(:ssrc_router)]

    new_spec = %ParentSpec{children: children, links: links}

    parsers_by_pads = state.parsers_by_pads |> Map.put(pad, parser_ref)

    state = %{state | parsers_by_pads: parsers_by_pads}

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
      |> state.pt_to_depayloader.()

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
  def handle_pad_removed(Pad.ref(:input, _id) = pad, _ctx, state) do
    {parser_to_remove, new_parsers_by_pads} = state.parsers_by_pads |> Map.pop(pad)

    {{:ok, remove_child: parser_to_remove}, %State{state | parsers_by_pads: new_parsers_by_pads}}
  end

  @impl true
  def handle_pad_removed(Pad.ref(:output, _ssrc), _ctx, state) do
    {:ok, state}
  end

  @impl true
  def handle_notification({:new_rtp_stream, ssrc, fmt}, :ssrc_router, state) do
    {:ok, payload_type} = get_payload_type(fmt, state.fmt_mapping)

    %State{ssrc_pt_mapping: ssrc_pt_mapping} = state

    new_ssrc_pt_mapping = ssrc_pt_mapping |> Map.put(ssrc, payload_type)

    {{:ok, notify: {:new_rtp_stream, ssrc, payload_type}},
     %{state | ssrc_pt_mapping: new_ssrc_pt_mapping}}
  end

  defp get_payload_type(fmt, fmt_mapping) do
    case fmt_mapping do
      %{^fmt => payload_type} ->
        {:ok, payload_type}

      _ ->
        {:error, :not_found}
    end
  end

  @spec payload_type_to_depayloader(Receiver.SSRCRouter.payload_type()) :: module()
  def payload_type_to_depayloader("H264"), do: RTP.H264.Depayloader
  def payload_type_to_depayloader("MPA"), do: RTP.MPEGAudio.Depayloader
end
