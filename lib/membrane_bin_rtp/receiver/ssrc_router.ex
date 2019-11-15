defmodule Membrane.Bin.RTP.Receiver.SSRCRouter do
  @doc """
  A bin that receives parsed rtp packets
  and based on their ssrc routes them to an appropriate
  rtp session bin and creates one if the received packet
  is the first for this rtp stream.
  """

  use Membrane.Filter

  def_input_pad :input, demand_unit: :buffers, caps: :any, availability: :on_request

  def_output_pad :output, caps: :any, availability: :on_request

  @type ssrc :: integer()
  @type fmt :: integer()
  @type payload_type :: String.t()

  defmodule PadPair do
    @moduledoc false

    alias Membrane.Bin.SSRCRouter

    @type t() :: %__MODULE__{
            input_pad: nil | Pad.ref_t(),
            dest_pad: nil | Pad.ref_t()
          }

    defstruct input_pad: nil, dest_pad: nil
  end

  defmodule State do
    @moduledoc false

    alias Membrane.Bin.SSRCRouter

    @type t() :: %__MODULE__{
            pads: %{SSRCRouter.ssrc() => [PadPair.t()]},
            linking_buffers: %{SSRCRouter.ssrc() => [Membrane.Buffer.t()]}
          }

    defstruct pads: %{},
              linking_buffers: %{}
  end

  @impl true
  def handle_init(_), do: {:ok, %State{}}

  @impl true
  def handle_pad_added(Pad.ref(:output, ssrc) = pad, _ctx, state) do
    %State{pads: pads, linking_buffers: lb} = state

    new_pads = Map.update!(pads, ssrc, &%{&1 | dest_pad: pad})
    {buffers_to_send, new_lb} = lb |> Map.pop(ssrc)
    new_state = %State{state | pads: new_pads, linking_buffers: new_lb}

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
      |> Enum.filter(fn {_ssrc, %PadPair{input_pad: p}} -> p != pad end)
      |> Enum.into(%{})

    {:ok, %State{state | pads: new_pads}}
  end

  @impl true
  def handle_prepared_to_playing(ctx, state) do
    actions =
      ctx.pads
      |> Enum.map(fn {pad_ref, _pad_data} -> {:demand, {pad_ref, 1}} end)

    {{:ok, actions}, state}
  end

  @impl true
  def handle_demand(Pad.ref(:output, ssrc), _size, _unit, ctx, state) do
    input_pad = state.pads[ssrc].input_pad

    {{:ok, demand: {input_pad, &(&1 + ctx.incoming_demand)}}, state}
  end

  @impl true
  def handle_process(Pad.ref(:input, _id) = pad, buffer, _ctx, state) do
    ssrc = buffer.metadata.rtp.ssrc

    cond do
      new_stream?(ssrc, state.pads) ->
        fmt = buffer.metadata.rtp.payload_type

        new_pads = state.pads |> Map.put(ssrc, %PadPair{input_pad: pad})

        {{:ok, notify: {:new_rtp_stream, ssrc, fmt}, demand: {pad, &(&1 + 1)}},
         %{
           state
           | pads: new_pads,
             linking_buffers: Map.put(state.linking_buffers, ssrc, [buffer])
         }}

      waiting_for_linking?(ssrc, state) ->
        new_state = %{
          state
          | linking_buffers: Map.update(state.linking_buffers, ssrc, [buffer], &[buffer | &1])
        }

        {:ok, new_state}

      true ->
        %{^ssrc => %PadPair{dest_pad: dest_pad}} = state.pads

        {{:ok, buffer: {dest_pad, buffer}}, state}
    end
  end

  defp waiting_for_linking?(ssrc, %State{linking_buffers: lb}), do: Map.has_key?(lb, ssrc)

  defp new_stream?(ssrc, pads), do: not Map.has_key?(pads, ssrc)
end
