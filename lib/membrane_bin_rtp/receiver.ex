defmodule Membrane.Bin.RTP.Receiver do
  @moduledoc """
  A bin consuming one or more RTP streams on each input and outputting a stream from one SSRC on
  each output. Every stream is parsed and then (based on SSRC field) an appropriate RTP session is
  initiated.

  This bin also supports processing RTCP packets. RTCP packets with a clear purpose, like Bye and
  CNAME, are handled inside the bin.

  The notifications this bin sends are as follows:
  `{:new_rtp_stream, ssrc, payload_type}` - when a new stream starts. Parent should then connect
    to RTP bin dynamic output pad instance that will have an id == `ssrc`.
  `{:closed_rtp_stream, SSRC, cause}` - when a stream ends (RTCP Bye received)
  `{:named_rtp_stream, SSRC, name}` - when a stream is first given a identifiable name (SDES CNAME
    received)
  `{:renamed_rtp_stream, SSRC, name}` - when a stream changes its name (a different SDES CNAME
    received)
  `{:rtcp, packet}` - when an unhandled RTCP packet is received (for example, APP, Receiver report
    or SDES with fields other than CNAME)
  """
  use Membrane.Bin
  use Bitwise

  @unhandled_sdes_types [:cname]

  alias Membrane.Bin.RTP.{PayloadType, Receiver}
  alias Membrane.Bin.RTP.Reporter
  alias Membrane.Element.RTP.{RTCP, RTCP}
  alias Membrane.ParentSpec

  def_options fmt_mapping: [
                spec: %{integer => PayloadType.t()},
                default: %{},
                description: "Mapping of the custom payload types (for fmt > 95)"
              ],
              pt_to_depayloader: [
                spec: (String.t() -> module()),
                default: &PayloadType.to_depayloader/1,
                description: "Mapping from payload type to a depayloader module"
              ],
              use_rtcp: [
                spec: boolean(),
                default: false,
                description: "Enable RTCP support"
              ],
              secure: [
                spec: boolean(),
                default: false,
                description: "Enable SRTP/SRTCP support"
              ]

  def_input_pad :input, demand_unit: :buffers, caps: :any, availability: :on_request

  def_output_pad :rtp, caps: :any, demand_unit: :buffers, availability: :on_request
  def_output_pad :rtcp, caps: :any, demand_unit: :buffers, availability: :on_request

  defmodule State do
    @moduledoc false

    defstruct fmt_mapping: %{},
              ssrc_pt_mapping: %{},
              pt_to_depayloader: nil,
              children_by_pads: %{},
              rtcp_pid: nil,
              names_to_ssrc: %{}
  end

  @impl true
  def handle_init(%{fmt_mapping: fmt_map, pt_to_depayloader: d_mapper}) do
    children = [
      ssrc_router: Receiver.SSRCRouter,
      rtcp: Reporter
    ]

    links = [
      link(:ssrc_router)
      |> via_out(:rtcp)
      |> to(:rtcp)
    ]

    spec = %ParentSpec{children: children, links: links}

    {{:ok, spec: spec}, %State{fmt_mapping: fmt_map, pt_to_depayloader: d_mapper}}
  end

  @impl true
  def handle_pad_added(Pad.ref(:input, _id) = pad, _ctx, state) do
    links = [link_bin_input(pad) |> to(:ssrc_router)]

    new_spec = %ParentSpec{links: links}

    {{:ok, spec: new_spec}, state}
  end

  @impl true
  def handle_pad_added(
        Pad.ref(:rtp, ssrc) = pad,
        _ctx,
        %State{ssrc_pt_mapping: ssrc_pt_mapping} = state
      ) do
    pt = Map.get(ssrc_pt_mapping, ssrc)
    depayloader = state.pt_to_depayloader.(pt.name)

    rtp_session_name = {:session, ssrc}

    new_children = [
      {rtp_session_name, %Receiver.Session{payload_type: pt, depayloader: depayloader}}
    ]

    new_links = [
      link(:rtcp)
      |> via_out(Pad.ref(:session, ssrc))
      |> via_in(:rtcp)
      |> to(rtp_session_name),
      link(:ssrc_router)
      |> via_out(Pad.ref(:rtp, ssrc))
      |> to(rtp_session_name)
      |> to_bin_output(pad)
    ]

    new_spec = %ParentSpec{children: new_children, links: new_links}
    new_children_by_pads = state.children_by_pads |> Map.put(pad, rtp_session_name)

    {{:ok, spec: new_spec}, %State{state | children_by_pads: new_children_by_pads}}
  end

  @impl true
  def handle_pad_added(
        Pad.ref(:rtcp, ssrc) = pad,
        _ctx,
        state
      ) do
    new_links = [
      link(:rtcp)
      |> via_out(Pad.ref(:report, ssrc))
      |> to_bin_output(pad)
    ]

    new_spec = %ParentSpec{links: new_links}
    {{:ok, spec: new_spec}, state}
  end

  @impl true
  def handle_pad_removed(pad, _ctx, state) do
    {session_to_remove, new_children_by_pads} = state.children_by_pads |> Map.pop(pad)

    {{:ok, remove_child: session_to_remove},
     %State{state | children_by_pads: new_children_by_pads}}
  end

  @impl true
  def handle_notification({:new_rtp_stream, ssrc, fmt}, :ssrc_router, state) do
    {:ok, %PayloadType{} = pt} = PayloadType.get_payload_type(fmt, state.fmt_mapping)

    %State{ssrc_pt_mapping: ssrc_pt_mapping} = state

    new_ssrc_pt_mapping = ssrc_pt_mapping |> Map.put(ssrc, pt)

    new_stream_info = {:new_rtp_stream, ssrc, pt}

    {{:ok, notify: new_stream_info, forward: {:rtcp, new_stream_info}},
     %{state | ssrc_pt_mapping: new_ssrc_pt_mapping}}
  end

  @impl true
  def handle_notification({:rtcp, %RTCP.SDES{chunks: chunks}}, :rtcp, state) do
    {state, notifications} = handle_cnames(state, chunks)

    remaining =
      chunks
      |> Enum.filter(fn {type, _ssrc, _name} -> type not in @unhandled_sdes_types end)
      |> Enum.map(&{:notify, &1})

    {{:ok, remaining ++ notifications}, state}
  end

  @impl true
  def handle_notification({:rtcp, %RTCP.Bye{ssrcs: ssrcs, reason: reason}}, :rtcp, state) do
    notifications = Enum.map(ssrcs, &{:notify, {:closed_rtp_stream, &1, reason}})
    {{:ok, notifications}, state}
  end

  @impl true
  def handle_notification({:rtcp, _packet} = notification, :rtcp, state) do
    {{:ok, notify: notification}, state}
  end

  defp handle_cnames(state, fields) do
    cnames =
      fields
      |> Enum.filter(&match?({:cname, _ssrc, _name}, &1))
      |> Enum.map(fn {:cname, ssrc, name} -> {name, ssrc} end)
      |> Enum.filter(fn pair -> pair not in state.names_to_ssrc end)

    notifications =
      cnames
      |> Enum.map(fn {name, ssrc} ->
        state.names_to_ssrc
        |> Map.has_key?(name)
        |> case do
          true -> {:moved_rtp_stream, ssrc, name}
          false -> {:named_rtp_stream, ssrc, name}
        end
        |> (&{:notify, &1}).()
      end)

    new_names =
      Enum.reduce(cnames, state.names_to_ssrc, fn {name, ssrc}, acc ->
        Map.put(acc, name, ssrc)
      end)

    {%{state | names_to_ssrc: new_names}, notifications}
  end
end
