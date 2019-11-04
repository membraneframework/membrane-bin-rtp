defmodule Membrane.Bin.SSRCRouter do
  use Membrane.Filter

  def_input_pad :input, demand_unit: :buffers, caps: :any, availability: :on_request

  def_output_pad :output, caps: :any, availability: :on_request, options: [ssrc: [type: :integer]]

  # TODO inject somehow
  @fmt_mapping %{96 => "H264", 127 => "MPA"}

  defmodule State do
    defstruct pads: %{}
  end

  @impl true
  def handle_init(_) do
    {:ok, %State{}}
  end

  @impl true
  def handle_pad_added({:dynamic, :output, _id} = pad, ctx, state) do
    %{ssrc: ssrc} = ctx.options

    IO.inspect state.pads, label: "state.pads in handle_pad_added"
    %State{pads: pads} = state

    new_state = %State{pads: Map.update!(pads, ssrc, &(%{&1 | dest_pad: pad}))}

    {:ok, new_state}
  end

  def handle_pad_added({:dynamic, :input, _id} = pad, _ctx, state) do
    {:ok, state}
  end

  @impl true
  def handle_prepared_to_playing(ctx, state) do
    actions =
    ctx.pads
    |> Enum.map(fn {pad_ref, _pad_data} -> {:demand, {pad_ref, 1}} end)

    {{:ok, actions}, state} # We need packet with ssrc to setup the rest of pipeline (rtp session). Then demands from it will be passed
  end

  @impl true
  def handle_demand(pad, size, _unit, ctx, state) do
    # TODO don't do it for all input pads
    IO.puts "handle_demand on pad #{inspect pad} (state.pads: #{inspect state.pads})"
    actions =
    ctx.pads
    |> Enum.map(fn {pad_ref, _data} -> pad_ref end)
    |> Enum.filter(fn {:dynamic, name, _id} -> name == :input end)
    |> Enum.map(fn pad_ref -> {:demand, {pad_ref, 1}} end)

    {{:ok, actions}, state}
  end

  @impl true
  def handle_process({:dynamic, :input, _id} = pad, buffer, ctx, state) do
    ssrc = get_ssrc(buffer)

    IO.puts "handle_process for #{if new_stream?(ssrc, state.pads), do: "new stream", else: "old stream"}. Pad: #{inspect pad}"

    if new_stream?(ssrc, state.pads) do
      {:ok, payload_type} = get_payload_type(buffer, @fmt_mapping)
      # TODO use `buffer` action on that first packet in handle_pad_added
      IO.inspect ssrc, label: "adding this ssrc to state.pads"
      new_pads = state.pads |> Map.put(ssrc, %{input_pad: pad, dest_pad: :not_assigned})
      {{:ok, notify: {:new_rtp_stream, ssrc, payload_type}}, %{state | pads: new_pads}}
    else
      %{^ssrc => %{dest_pad: dest_pad}} = state.pads
      {{:ok, buffer: {dest_pad, buffer}}, state}
    end
  end

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
