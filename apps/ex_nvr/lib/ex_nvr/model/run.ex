defmodule ExNVR.Model.Run do
  @moduledoc """
  A run represent a recording session.

  An example of a run would be an RTSP session from start to finish. It's a helpful
  module to get the available footages
  """

  use Ecto.Schema

  import Ecto.Query

  @type t :: %__MODULE__{
          start_date: DateTime.t(),
          end_date: DateTime.t(),
          active: boolean(),
          device_id: binary()
        }

  @foreign_key_type :binary_id
  schema "runs" do
    field(:start_date, :utc_datetime_usec)
    field(:end_date, :utc_datetime_usec)
    field(:active, :boolean, default: false)

    belongs_to :device, ExNVR.Model.Device
  end

  def deactivate_query(device_id) do
    from(r in __MODULE__, where: r.device_id == ^device_id and r.active == true)
  end

  def filter(query \\ __MODULE__, params) do
    Enum.reduce(params, query, fn
      {:device_id, id}, q -> where(q, [r], r.device_id == ^id)
      {:start_date, start_date}, q -> where(q, [r], r.end_date > ^start_date)
      _, q -> q
    end)
    |> order_by([r], asc: r.device_id, asc: r.start_date)
  end
end