defmodule Membrane.Bin.SSRCRouter do
  @doc """
  A bin that receives parsed rtp packets
  and based on their ssrc routes them to an appropriate
  rtp session bin and creates one if the received packet
  is the first for this rtp stream.
  """

  use Membrane.Filter

  def_options fmt_mapping: [type: :map]

  def_input_pad :input, demand_unit: :buffers, caps: :any, availability: :on_request

  def_output_pad :output, caps: :any, availability: :on_request

  @type ssrc :: integer()
  @type fmt :: integer()
  @type payload_type :: String.t()

  defmodule PadPair do
    @moduledoc false

    alias Membrane.Bin.SSRCRouter

    @type t() :: %__MODULE__{
            input_pad: :not_assigned | Pad.ref_t(),
            dest_pad: :not_assigned | Pad.ref_t()
          }

    defstruct input_pad: :not_assigned, dest_pad: :not_assigned
  end

  defmodule State do
    @moduledoc false

    alias Membrane.Bin.SSRCRouter

    @type t() :: %__MODULE__{
            pads: %{SSRCRouter.ssrc() => [PadPair.t()]},
            linking_buffers: %{SSRCRouter.ssrc() => [Membrane.Buffer.t()]},
            fmt_mapping: %{SSRCRouter.fmt() => SSRCRouter.payload_type()}
          }

    defstruct pads: %{},
              linking_buffers: %{},
              fmt_mapping: %{}
  end

  @impl true
  def handle_init(%{fmt_mapping: fmt_map}), do: {:ok, %State{fmt_mapping: fmt_map}}

  @impl true
  def handle_pad_added(Pad.ref(:output, ssrc) = pad, _ctx, state) do
    %State{pads: pads, linking_buffers: lb} = state

    new_pads = Map.update!(pads, ssrc, &%{&1 | dest_pad: pad})
    {buffers_to_send, new_lb} = lb |> Map.pop(ssrc)
    new_state = %State{state | pads: new_pads, linking_buffers: new_lb}

    {{:ok, buffer: {pad, buffers_to_send}}, new_state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:input, _id), _ctx, state) do
    {:ok, state}
  end

  @impl true
  def handle_prepared_to_playing(ctx, state) do
    actions =
      ctx.pads
      |> Enum.map(fn {pad_ref, _pad_data} -> {:demand, {pad_ref, 1}} end)

    {{:ok, actions}, state}
  end

  @impl true
  def handle_demand(_pad, _size, _unit, _ctx, %State{linking_buffers: true} = state) do
    {:ok, state}
  end

  @impl true
  def handle_demand(pad, _size, _unit, ctx, state) do
    %PadPair{input_pad: input_pad} =
      state.pads
      |> Map.values()
      |> Enum.find(fn %PadPair{dest_pad: pad_ref} -> pad_ref == pad end)

    {{:ok, demand: {input_pad, &(&1 + ctx.incoming_demand)}}, state}
  end

  @impl true
  def handle_process(Pad.ref(:input, _id) = pad, buffer, _ctx, state) do
    ssrc = get_ssrc(buffer)

    cond do
      new_stream?(ssrc, state.pads) ->
        {:ok, payload_type} = get_payload_type(buffer, state.fmt_mapping)

        new_pads = state.pads |> Map.put(ssrc, %PadPair{input_pad: pad})

        {{:ok, notify: {:new_rtp_stream, ssrc, payload_type}},
         %{
           state
           | pads: new_pads,
             linking_buffers: Map.put(state.linking_buffers, ssrc, [buffer])
         }}

      waiting_for_linking?(ssrc, state) ->
        new_state = %{
          state
          | linking_buffers: Map.update(state.linking_buffers, ssrc, [buffer], &(&1 ++ [buffer]))
        }

        {:ok, new_state}

      true ->
        %{^ssrc => %PadPair{dest_pad: dest_pad}} = state.pads

        {{:ok, buffer: {dest_pad, buffer}}, state}
    end
  end

  defp waiting_for_linking?(ssrc, %State{linking_buffers: lb}), do: Map.has_key?(lb, ssrc)

  defp get_ssrc(%Membrane.Buffer{metadata: %{rtp: %{ssrc: ssrc}}}), do: ssrc

  defp get_payload_type(%Membrane.Buffer{metadata: %{rtp: %{payload_type: fmt}}}, fmt_mapping) do
    case fmt_mapping do
      %{^fmt => payload_type} ->
        {:ok, payload_type}

      _ ->
        {:error, :not_found}
    end
  end

  defp new_stream?(ssrc, pads), do: not Map.has_key?(pads, ssrc)
end
