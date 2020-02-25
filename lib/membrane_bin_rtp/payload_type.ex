defmodule Membrane.Bin.RTP.PayloadType do
  @moduledoc """
  Functions for mapping payload types (integers) into their parameters and depayloaders.
  """

  alias Membrane.Element.RTP
  alias Membrane.Element.RTP.Receiver.SSRCRouter

  @static_fmt_file "rtp-parameters-1.csv" |> Path.expand(__DIR__)

  @type t() :: %__MODULE__{
          id: 0..127,
          name: String.t(),
          mediatype: String.t(),
          clockrate: non_neg_integer(),
          channels: 1 | 2 | nil
        }

  defstruct [:id, :name, :mediatype, :clockrate, :channels]

  def get_payload_type(fmt, fmt_mapping) do
    case fmt_to_pt(fmt) do
      {:ok, pt} ->
        {:ok, pt}

      {:error, :not_static} ->
        if pt = fmt_mapping[fmt], do: {:ok, pt}, else: {:error, :pt_not_found}
    end
  end

  @spec to_depayloader(SSRCRouter.payload_type()) :: module()
  def to_depayloader("H264"), do: RTP.H264.Depayloader
  def to_depayloader("MPA"), do: RTP.MPEGAudio.Depayloader

  File.stream!(@static_fmt_file)
  |> CSV.decode!()
  |> Stream.drop(1)
  |> Enum.filter(fn [_, pt | _] ->
    pt != "Unassigned" and pt != "dynamic" and not String.starts_with?(pt, "Reserved")
  end)
  |> Enum.map(fn
    [fmt_s, name, av, clockrate_s, channels_s, _] ->
      {fmt, ""} = fmt_s |> Integer.parse()
      {clockrate, ""} = clockrate_s |> Integer.parse()

      channels =
        if channels_s == "" do
          nil
        else
          {channels, ""} = Integer.parse(channels_s)
          channels
        end

      defp fmt_to_pt(unquote(fmt)),
        do:
          {:ok,
           %__MODULE__{
             name: unquote(name),
             mediatype: unquote(av),
             clockrate: unquote(clockrate),
             channels: unquote(channels)
           }}
  end)

  defp fmt_to_pt(_), do: {:error, :not_static}
end
