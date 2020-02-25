defmodule Membrane.Bin.RTP.Receiver.SSRCRouter do
  @moduledoc """
  A bin that receives parsed rtp packets
  and based on their ssrc routes them to an appropriate
  rtp session bin and creates one if the received packet
  is the first for this rtp stream.
  """

  use Membrane.Filter

  alias Membrane.Bin.RTP.Reporter

  def_input_pad :input, demand_unit: :buffers, caps: :any, availability: :on_request

  def_output_pad :rtp, caps: :any, availability: :on_request
  def_output_pad :rtcp, caps: :any

  @type ssrc :: integer()
  @type fmt :: integer()
  @type payload_type :: String.t()

  defmodule State do
    @moduledoc false

    alias Membrane.Bin.RTP.Receiver.SSRCRouter

    @type t() :: %__MODULE__{
            pads: %{SSRCRouter.ssrc() => [input_pad :: Pad.ref_t()]},
            linking_buffers: %{SSRCRouter.ssrc() => [Membrane.Buffer.t()]}
          }

    defstruct pads: %{},
              linking_buffers: %{}
  end

  @impl true
  def handle_init(_), do: {:ok, %State{}}

  @impl true
  def handle_pad_added(Pad.ref(:rtp, ssrc) = pad, _ctx, state) do
    %State{linking_buffers: lb} = state

    {buffers_to_send, new_lb} = lb |> Map.pop(ssrc)
    new_state = %State{state | linking_buffers: new_lb}

    {{:ok, buffer: {pad, Enum.reverse(buffers_to_send)}}, new_state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:input, _id), _ctx, state) do
    {:ok, state}
  end

  @impl true
  def handle_pad_removed(Pad.ref(:input, _) = pad, _ctx, state) do
    new_pads =
      state.pads
      |> Enum.filter(fn {_ssrc, p} -> p != pad end)
      |> Enum.into(%{})

    {:ok, %State{state | pads: new_pads}}
  end

  @impl true
  def handle_prepared_to_playing(ctx, state) do
    actions =
      ctx.pads
      |> Map.to_list()
      |> Enum.filter(&match?({_name, %Membrane.Pad.Data{direction: :input}}, &1))
      |> Enum.map(fn {pad_ref, _pad_data} -> {:demand, {pad_ref, 1}} end)

    {{:ok, actions}, state}
  end

  @impl true
  def handle_demand(Pad.ref(:rtp, ssrc), _size, _unit, ctx, state) do
    input_pad = state.pads[ssrc]

    {{:ok, demand: {input_pad, &(&1 + ctx.incoming_demand)}}, state}
  end

  @impl true
  def handle_demand(_pad, _size, _unit, _ctx, state) do
    {:ok, state}
  end

  @impl true
  def handle_process(Pad.ref(:input, _id) = pad, buffer, _ctx, state) do
    <<_::9, fmt::7, _::48, ssrc::32, _::binary>> = buffer.payload
    output_pad = get_output_pad(buffer.payload, ssrc)
    buffer = put_arrival_timestamp(buffer)

    cond do
      is_rtcp?(buffer.payload) ->
        {{:ok, buffer: {output_pad, buffer}, demand: {pad, &(&1 + 1)}}, state}

      new_stream?(ssrc, state.pads) ->
        new_pads = state.pads |> Map.put(ssrc, pad)

        {{:ok, notify: {:new_rtp_stream, ssrc, fmt}, demand: {pad, &(&1 + 1)}},
         %{
           state
           | pads: new_pads,
             linking_buffers: Map.put(state.linking_buffers, ssrc, [buffer])
         }}

      waiting_for_linking?(ssrc, state) ->
        new_state = %{
          state
          | linking_buffers: Map.update!(state.linking_buffers, ssrc, &[buffer | &1])
        }

        {{:ok, demand: {pad, &(&1 + 1)}}, new_state}

      true ->
        {{:ok, buffer: {output_pad, buffer}}, state}
    end
  end

  @impl true
  def handle_caps(_pad, _caps, _ctx, state) do
    # TODO Merge this element with Membrane.RTP.Parser and then handle caps correctly.
    # For now information about streams are in buffers metadata
    {:ok, state}
  end

  defp put_arrival_timestamp(buffer),
    # TODO put this in as a float (seconds)
    do:
      put_in(
        buffer,
        [Access.key!(:metadata), :ntp],
        %{arrival_timestamp: Reporter.get_ntp_timestamp()}
      )

  defp waiting_for_linking?(ssrc, %State{linking_buffers: lb}), do: Map.has_key?(lb, ssrc)

  defp new_stream?(ssrc, pads), do: not Map.has_key?(pads, ssrc)

  defp get_output_pad(packet, ssrc) do
    if is_rtcp?(packet), do: :rtcp, else: Pad.ref(:rtp, ssrc)
  end

  defp is_rtcp?(packet) do
    <<_::8, pt::8, _::binary>> = packet
    pt in 200..205
  end
end
