defmodule Membrane.Bin.RTP.Reporter do
  @moduledoc """
  RTCP packet processing.

  RTCP is described in [RFC3550](https://tools.ietf.org/html/rfc3550)

  This element aggregates data received from receiver sessions into RTCP Receiver Reports grouped
  by the mediatype of a receiving session. This is clarified/described in
  [RFC8108](https://tools.ietf.org/html/rfc8108)

  Incoming RTCP packets may be encrypted - authentication and decryption is implemented in
  Membrane.Element.RTP.
  """

  use Membrane.Filter
  use Bitwise
  use Bunch

  @max_uint (1 <<< 32) - 1

  # The gap between year 1900 and 1970 in seconds
  @timegap 2_208_988_800
  @s_to_ns 1_000_000_000

  alias Membrane.Bin.RTP.PayloadType
  alias Membrane.Core.Timer
  alias Membrane.Element.RTP.RTCP.{Report, ReportBlock}
  alias Membrane.Element.RTP.RTCP

  def_input_pad :input, caps: :any, demand_unit: :buffers

  def_output_pad :session, caps: :any, availability: :on_request
  def_output_pad :report, caps: :any, availability: :on_request

  defmodule State do
    @moduledoc """
    State of the RTCP controller. Dummy_ssrcs are used to hold persistent fake SSRC for a type of
    media received by multiple RTP receiver sessions.
    """
    defstruct timer_ref: nil,
              receiver_info: %{},
              receiver_data: %{},
              dummy_ssrcs: %{},
              last_sr_time: nil

    # time - values for mapping RTP time of one SSRC into NTP
    @type receiver_t :: %{
            payload_type: PayloadType.t(),
            time: {scale :: float(), offset :: float()}
          }

    @type t :: %__MODULE__{
            timer_ref: nil,
            receiver_info: %{(ssrc :: non_neg_integer()) => receiver_t()},
            receiver_data: %{(ssrc :: non_neg_integer()) => list()},
            dummy_ssrcs: %{(mediatype :: String.t()) => ssrc :: non_neg_integer()},
            last_sr_time: binary() | nil
          }
  end

  @impl true
  def handle_init(_opts) do
    {:ok, %State{}}
  end

  @impl true
  def handle_prepared_to_playing(_ctx, state) do
    interval = 200
    {:ok, timer} = :timer.send_interval(interval, :collect_report)
    {{:ok, demand: {:input, 1}}, %State{state | timer_ref: [timer]}}
  end

  @impl true
  def handle_playing_to_prepared(_ctx, %{timer_ref: timers} = state) do
    timers |> Enum.each(&Timer.stop(&1))
    {:ok, Map.delete(state, :timer_ref)}
  end

  @impl true

  @impl true
  def handle_process(:input, buffer, _ctx, state) do
    buffer.payload
    |> RTCP.parse_compound()
    |> case do
      {:ok, packets} ->
        actions =
          packets
          |> Enum.map(&{:notify, {:rtcp, &1}})
          |> Keyword.put(:demand, {:input, 1})

        # TODO save info about time
        {{:ok, actions}, state}

      {:error, cause} ->
        {{:error, cause}, state}
    end
  end

  @impl true
  def handle_demand(Pad.ref(_pad, _ssrc), size, _unit, _ctx, state) do
    {{:ok, demand: {:input, size}}, state}
  end

  @impl true
  def handle_event(
        Pad.ref(:session, ssrc),
        %Membrane.Event.RTCP.Metadata{} = metadata,
        _ctx,
        %State{
          receivers: receivers,
          receiver_data: receiver_data,
          dummy_ssrcs: dummy_ssrcs
        } = state
      ) do
    receiver_data = Map.put(receiver_data, ssrc, metadata)

    # TODO determine which ssrcs should receive the report
    output_pads = [ssrc] |> Enum.map(&Pad.ref(:report, &1))

    {report_actions, receiver_data} =
      if map_size(receiver_data) == map_size(receiver_info) do
        {report, state} = make_report(state)
        report = %Membrane.Buffer{payload: report}

        actions = Enum.map(output_pads, fn pad -> {:buffer, {pad, report}} end)
        {actions, %{}}
      else
        {[], receiver_data}
      end

    {{:ok, report_actions}, %{state | receiver_data: receiver_data}}
  end

  @impl true
  def handle_other(
        :collect_report,
        _ctx,
        %State{
          receiver_info: receiver_info,
          receiver_data: receiver_data,
          dummy_ssrcs: dummy_ssrcs
        } = state
      ) do
    requests =
      receiver_info
      |> Enum.map(fn {ssrc, _infos} ->
        {:event, {Pad.ref(:session, ssrc), %Membrane.Event.RTCP.MetadataRequest{}}}
      end)

    {{:ok, requests}, %{state | receiver_data: %{}}}
  end

  @impl true
  def handle_other({:new_rtp_stream, ssrc, payload_type}, _ctx, state) do
    # TODO does this work without Access.key! ?
    state =
      state
      |> put_in([Access.key!(:receiver_info), ssrc, :payload_type], payload_type)
      |> add_missing_dummy_ssrcs()

    {:ok, state}
  end

  defp make_report(
         %State{
           receiver_info: receiver_info,
           receiver_data: receiver_data,
           dummy_ssrcs: dummy_ssrcs
         } = state
       ) do
    ssrcs_by_reporting_ssrc =
      receiver_info
      |> Enum.group_by(
        fn {_ssrc, %{payload_type: payload_type}} -> dummy_ssrcs[payload_type.mediatype] end,
        fn {ssrc, _pt} -> ssrc end
      )

    binary_report =
      ssrcs_by_reporting_ssrc
      |> Enum.map(fn {reporting_ssrc, ssrcs} ->
        reports =
          receiver_data
          |> Map.take(ssrcs)
          |> Enum.map(make_report_block())

        %Report{
          ssrc: reporting_ssrc,
          sender_info: nil,
          reports: reports
        }
      end)
      |> RTCP.to_binary(nil)

    state = %{state | receiver_data: %{}}
    {binary_report, state}
  end

  defp make_report_block(datas) do
    datas
    |> Enum.map(fn {ssrc, data} ->
      # TODO calc last_sr i delay_last_sr
      # TODO last_sr provided in data
      delay_last_sr = calc_delay(data[:last_sr])

      data =
        data
        |> Map.from_struct()
        |> Map.put(:ssrc, ssrc)
        |> Map.put(:delay_last_sr, delay_last_sr)

      struct(ReportBlock, data)
    end)
  end

  defp add_missing_dummy_ssrcs(state) do
    new_dummy_ssrcs =
      state.receiver_info
      |> Enum.map(fn {_ssrc, %{payload_type: pt}} -> pt.mediatype end)
      |> Enum.uniq()
      |> Enum.filter(&(!Map.has_key?(state.dummy_ssrcs, &1)))
      |> Map.new(fn mt -> {mt, random_ssrc()} end)
      |> Map.merge(state.dummy_ssrcs)

    %{state | dummy_ssrcs: new_dummy_ssrcs}
  end

  defp random_ssrc do
    # According to RFC 3550 8. a simple approach (just uniform(...) with time as seed) is not good
    # enough. This is loosely based on code in the rfc and might be good enough
    {:ok, host} = :inet.gethostname()
    host = host |> to_string |> :binary.decode_unsigned()
    state = :rand.seed(:exsss, :erlang.system_time() + host)
    {ssrc, _state} = :rand.uniform_s(@max_uint, state)
    ssrc
  end

  defp calc_delay(last_sr) do
    current_ntp_time = 0
    current_ntp_time - last_sr
  end

  defp convert_ntp_to_rtp_time(ntp_time) do
    <<seconds::32, fraction::32>> = <<ntp_time::64>>
    ((seconds - @timegap + fraction / @max_uint) * @s_to_ns) |> trunc
  end

  # TODO move this somewhere i sprawdzić czy to wgl działa
  def get_ntp_timestamp(), do: Membrane.Time.os_time() + @timegap
end
