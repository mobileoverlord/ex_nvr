defmodule ExNVR.Elements.RTSP.ConnectionManager do
  @moduledoc false

  use Connection

  require Membrane.Logger

  alias Membrane.RTSP

  defmodule ConnectionStatus do
    @moduledoc false
    use Bunch.Access

    @type t :: %__MODULE__{
            stream_uri: binary(),
            rtsp_session: pid(),
            endpoint: pid(),
            endpoint_options: map(),
            reconnect_delay: non_neg_integer(),
            max_reconnect_attempts: non_neg_integer() | :infinity,
            reconnect_attempt: non_neg_integer()
          }

    @enforce_keys [
      :stream_uri,
      :endpoint,
      :endpoint_options,
      :reconnect_delay,
      :max_reconnect_attempts,
      :reconnect_attempt
    ]

    defstruct @enforce_keys ++ [:rtsp_session]
  end

  @spec reconnect(GenServer.server()) :: :ok
  def reconnect(connection_manager) do
    GenServer.cast(connection_manager, :reconnect)
  end

  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(args) do
    Membrane.Logger.debug("ConnectionManager: start_link, args: #{inspect(args)}")

    Connection.start_link(__MODULE__, args)
  end

  @spec start(Keyword.t()) :: GenServer.on_start()
  def start(args) do
    Membrane.Logger.debug("ConnectionManager: start, args: #{inspect(args)}")

    Connection.start(__MODULE__, args)
  end

  @impl true
  def init(opts) do
    Membrane.Logger.debug("ConnectionManager: Initializing")

    Process.monitor(opts[:endpoint])

    {:connect, :init,
     %ConnectionStatus{
       stream_uri: opts[:stream_uri],
       endpoint: opts[:endpoint],
       endpoint_options: %{
         rtpmap: nil,
         fmtp: nil,
         control: nil
       },
       reconnect_delay: opts[:reconnect_delay],
       max_reconnect_attempts: opts[:max_reconnect_attempts],
       reconnect_attempt: 0
     }}
  end

  @impl true
  def connect(info, %ConnectionStatus{} = connection_status) do
    Membrane.Logger.debug("ConnectionManager: Connecting (info: #{inspect(info)})")

    rtsp_session = start_rtsp_session(connection_status)
    connection_status = %{connection_status | rtsp_session: rtsp_session}

    if is_nil(rtsp_session) do
      maybe_reconnect(connection_status)
    else
      try do
        with {:ok, connection_status} <- get_rtsp_description(connection_status),
             {:ok, connection_status} <- setup_rtsp_connection(connection_status),
             :ok <- play(connection_status) do
          send(
            connection_status.endpoint,
            {:rtsp_setup_complete, connection_status.endpoint_options}
          )

          {:ok, %{connection_status | reconnect_attempt: 0}}
        else
          {:error, :unauthorized} ->
            Membrane.Logger.debug(
              "ConnectionManager: Unauthorized. Attempting immediate reconnect..."
            )

            {:backoff, 0, connection_status}

          {:error, error} ->
            Membrane.Logger.debug("ConnectionManager: Connection failed: #{inspect(error)}")

            send(connection_status.endpoint, {:connection_info, {:connection_failed, error}})

            maybe_reconnect(connection_status)
        end
      catch
        # We catch exits here because the process crash before
        # RTSP session returns timeout
        :exit, error ->
          Membrane.Logger.error("""
          EXIT error when trying to connect to rtsp server
          #{inspect(error)}
          """)

          # A strange bug in membrane RTSP, when the media data are sent
          # with the PLAY response, the rtsp session doesn't respond and enter
          # an infinite loop
          Process.exit(connection_status.rtsp_session, :kill)
          {:ok, connection_status}
      end
    end
  end

  @impl true
  def disconnect(message, %ConnectionStatus{} = connection_status) do
    Membrane.Logger.debug("ConnectionManager: Disconnecting: #{message}")

    kill_children(connection_status)

    connection_status = %{connection_status | rtsp_session: nil}

    send(connection_status.endpoint, {:connection_info, :disconnected})

    {:noconnect, connection_status, :hibernate}
  end

  defp kill_children(%ConnectionStatus{rtsp_session: rtsp_session}) do
    if !is_nil(rtsp_session) and Process.alive?(rtsp_session), do: RTSP.close(rtsp_session)
  end

  @impl true
  def handle_cast(:reconnect, %ConnectionStatus{} = connection_status) do
    Membrane.Logger.debug("ConnectionManager: Received reconnect request")

    connection_status = %{connection_status | reconnect_attempt: 1}

    if not is_nil(connection_status.rtsp_session) do
      Membrane.Logger.debug("ConnectionManager: close current connection and reconnect")
      RTSP.close(connection_status.rtsp_session)
    end

    {:connect, :reload, %{connection_status | rtsp_session: nil}}
  end

  @impl true
  def handle_info(
        {:DOWN, _ref, :process, pid, reason},
        %ConnectionStatus{rtsp_session: pid} = connection_status
      )
      when reason != :normal do
    send(connection_status.endpoint, {:connection_info, {:connection_failed, :session_crashed}})
    {:connect, :reload, %{connection_status | rtsp_session: nil}}
  end

  @impl true
  def handle_info(
        {:DOWN, _ref, :process, pid, reason},
        %ConnectionStatus{endpoint: pid} = connection_status
      ) do
    kill_children(connection_status)
    {:stop, reason, connection_status}
  end

  @impl true
  def handle_info(_, state) do
    {:noreply, state}
  end

  defp maybe_reconnect(
         %ConnectionStatus{
           endpoint: endpoint,
           reconnect_attempt: attempt,
           max_reconnect_attempts: max_attempts,
           reconnect_delay: delay
         } = connection_status
       ) do
    connection_status = %{connection_status | reconnect_attempt: attempt + 1}

    # This works with :infinity, since integers < atoms
    if attempt < max_attempts do
      {:backoff, delay, connection_status}
    else
      Membrane.Logger.debug("ConnectionManager: Max reconnect attempts reached. Hibernating")
      send(endpoint, {:connection_info, :max_reconnects})
      {:ok, connection_status, :hibernate}
    end
  end

  defp start_rtsp_session(%ConnectionStatus{
         rtsp_session: nil,
         stream_uri: stream_uri,
         endpoint: endpoint
       }) do
    case RTSP.start(stream_uri, ExNVR.Elements.RTSP.TCPSocket, media_receiver: endpoint) do
      {:ok, session} ->
        Process.monitor(session)
        session

      {:error, error} ->
        Membrane.Logger.debug(
          "ConnectionManager: Starting RTSP session failed - #{inspect(error)}"
        )

        send(endpoint, {:connection_info, {:connection_failed, error}})

        nil
    end
  end

  defp start_rtsp_session(%ConnectionStatus{rtsp_session: rtsp_session}) do
    rtsp_session
  end

  defp get_rtsp_description(%ConnectionStatus{rtsp_session: rtsp_session} = connection_status) do
    Membrane.Logger.debug("ConnectionManager: Setting up RTSP description")

    case RTSP.describe(rtsp_session) do
      {:ok, %{status: 200} = response} ->
        attributes = get_video_attributes(response)

        connection_status =
          connection_status
          |> put_in([:endpoint_options, :control], get_attribute(attributes, "control", ""))
          |> put_in([:endpoint_options, :fmtp], get_attribute(attributes, ExSDP.Attribute.FMTP))
          |> put_in(
            [:endpoint_options, :rtpmap],
            get_attribute(attributes, ExSDP.Attribute.RTPMapping)
          )

        {:ok, connection_status}

      {:ok, %{status: 401}} ->
        {:error, :unauthorized}

      _result ->
        {:error, :getting_rtsp_description_failed}
    end
  end

  defp setup_rtsp_connection(
         %ConnectionStatus{
           rtsp_session: rtsp_session,
           endpoint_options: endpoint_options
         } = connection_status
       ) do
    Membrane.Logger.debug("ConnectionManager: Setting up RTSP connection")

    case RTSP.setup(rtsp_session, endpoint_options.control, [
           {"Transport", "RTP/AVP/TCP;interleaved=0-1"}
         ]) do
      {:ok, %{status: 200}} ->
        {:ok, connection_status}

      result ->
        Membrane.Logger.debug(
          "ConnectionManager: Setting up RTSP connection failed: #{inspect(result)}"
        )

        {:error, :setting_up_sdp_connection_failed}
    end
  end

  defp play(%ConnectionStatus{rtsp_session: rtsp_session}) do
    Membrane.Logger.debug("ConnectionManager: Setting RTSP on play mode")

    case RTSP.play(rtsp_session) do
      {:ok, %{status: 200}} ->
        :ok

      _result ->
        {:error, :play_rtsp_failed}
    end
  end

  defp get_video_attributes(%{body: %ExSDP{media: media_list}}) do
    media_list |> Enum.find(fn elem -> elem.type == :video end)
  end

  defp get_attribute(video_attributes, attribute, default \\ nil) do
    case ExSDP.Media.get_attribute(video_attributes, attribute) do
      {^attribute, value} -> value
      %^attribute{} = value -> value
      _other -> default
    end
  end
end