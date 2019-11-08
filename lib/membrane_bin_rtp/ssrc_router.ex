defmodule Membrane.Bin.SSRCRouter do
  use Membrane.Filter

  def_input_pad :input, demand_unit: :buffers, caps: :any, availability: :on_request

  def_output_pad :output, caps: :any, availability: :on_request, options: [ssrc: [type: :integer]]

  # TODO inject somehow
  @fmt_mapping %{96 => "H264", 127 => "MPA"}

  defmodule PadPair do
    defstruct input_pad: :not_assigned, dest_pad: :not_assigned
  end

  defmodule State do
    defstruct pads: %{}, waiting_for_linking: %{}
  end

  @impl true
  def handle_init(_), do: {:ok, %State{}}

  @impl true
  def handle_pad_added(Pad.ref(:output, _id) = pad, ctx, state) do
    %{ssrc: ssrc} = ctx.options

    %State{pads: pads, waiting_for_linking: lb} = state

    new_pads = Map.update!(pads, ssrc, &%{&1 | dest_pad: pad})

    {buffers_to_resend, new_lb} = lb |> Map.pop(ssrc)

    new_state = %State{pads: new_pads, waiting_for_linking: new_lb}

    actions = [{:buffer, {pad, Enum.reverse(buffers_to_resend)}}]

    {{:ok, actions}, new_state}
  end

  def handle_pad_added(Pad.ref(:input, _id) = pad, _ctx, state) do
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
  def handle_demand(pad, size, _unit, ctx, %State{waiting_for_linking: true} = state) do
    {:ok, state}
  end

  def handle_demand(pad, size, _unit, ctx, state) do
    %PadPair{input_pad: input_pad} =
      state.pads
      |> Map.values()
      |> Enum.find(fn %PadPair{dest_pad: pad_ref} -> pad_ref == pad end)

    {{:ok, demand: {input_pad, size}}, state}
  end

  @impl true
  def handle_process(Pad.ref(:input, _id) = pad, buffer, ctx, state) do
    ssrc = get_ssrc(buffer)

    cond do
      new_stream?(ssrc, state.pads) ->
        {:ok, payload_type} = get_payload_type(buffer, @fmt_mapping)

        new_pads = state.pads |> Map.put(ssrc, %PadPair{input_pad: pad})

        {{:ok, notify: {:new_rtp_stream, ssrc, payload_type}},
         %{
           state
           | pads: new_pads,
             waiting_for_linking: Map.put(state.waiting_for_linking, ssrc, [buffer])
         }}

      waiting_for_linking?(ssrc, state) ->
        new_state = %{
          state
          | waiting_for_linking:
              Map.update(state.waiting_for_linking, ssrc, [buffer], &[buffer | &1])
        }

        {:ok, new_state}

      true ->
        %{^ssrc => %PadPair{dest_pad: dest_pad} = ssrc_pads} = state.pads

        actions = [demand: {pad, 10}, buffer: {dest_pad, buffer}]

        {{:ok, actions}, state}
    end
  end

  defp waiting_for_linking?(ssrc, %State{waiting_for_linking: lb}), do: Map.has_key?(lb, ssrc)

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
