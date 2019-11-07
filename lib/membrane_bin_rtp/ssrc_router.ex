defmodule Membrane.Bin.SSRCRouter do
  use Membrane.Filter

  def_input_pad :input, demand_unit: :buffers, caps: :any, availability: :on_request

  def_output_pad :output, caps: :any, availability: :on_request, options: [ssrc: [type: :integer]]

  # TODO inject somehow
  @fmt_mapping %{96 => "H264", 127 => "MPA"}

  defmodule PadPair do
    defstruct input_pad: :not_assigned, dest_pad: :not_assigned

    def initialized?(%PadPair{input_pad: :not_assigned}), do: false
    def initialized?(%PadPair{dest_pad: :not_assigned}), do: false
    def initialized?(_), do: true
  end

  defmodule State do
    defstruct pads: %{}
  end

  @impl true
  def handle_init(_) do
    {:ok, %State{}}
  end

  @impl true
  def handle_pad_added({:dynamic, :output, _id} = pad, ctx, state) do
    IO.puts("handle_pad_added/3 called")
    %{ssrc: ssrc} = ctx.options

    %State{pads: pads} = state

    new_pads = Map.update!(pads, ssrc, &%{&1 | dest_pad: pad})

    new_state = %State{pads: new_pads}

    {{:ok, redemand: pad}, new_state}
  end

  def handle_pad_added({:dynamic, :input, _id} = pad, _ctx, state) do
    IO.puts("handle_pad_added/3 called")
    {:ok, state}
  end

  @impl true
  def handle_prepared_to_playing(ctx, state) do
    IO.puts("handle_prepared_to_playing/2 called")

    actions =
      ctx.pads
      |> Enum.map(fn {pad_ref, _pad_data} -> {:demand, {pad_ref, 1}} end)

    # We need packet with ssrc to setup the rest of pipeline (rtp session). Then demands from it will be passed
    {{:ok, actions}, state}
  end

  @impl true
  def handle_demand(pad, size, _unit, ctx, state) do
    IO.puts("handle_demand/5 called")

    %PadPair{input_pad: input_pad} =
      state.pads
      |> Map.values()
      |> Enum.find(fn %PadPair{dest_pad: pad_ref} -> pad_ref == pad end)

    {{:ok, demand: {input_pad, 1}}, state}
  end

  @impl true
  def handle_process({:dynamic, :input, _id} = pad, buffer, ctx, state) do
    IO.puts("handle_process/4 called (#{inspect(buffer.metadata)})")
    ssrc = get_ssrc(buffer)

    if new_stream?(ssrc, state.pads) do
      {:ok, payload_type} = get_payload_type(buffer, @fmt_mapping)

      new_pads = state.pads |> Map.put(ssrc, %PadPair{input_pad: pad})

      {{:ok, notify: {:new_rtp_stream, ssrc, payload_type}, demand: {pad, 0}},
       %{state | pads: new_pads}}
    else
      %{^ssrc => %PadPair{dest_pad: dest_pad} = ssrc_pads} = state.pads

      actions =
        [demand: {pad, 10}] ++
          if PadPair.initialized?(ssrc_pads) do
            [buffer: {dest_pad, buffer}]
          else
            []
          end

      {{:ok, actions}, state}
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
