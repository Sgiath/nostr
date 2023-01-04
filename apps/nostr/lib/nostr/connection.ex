defmodule Nostr.Connection do
  use GenServer

  require Logger

  def start_link(opts) do
    url = Keyword.fetch!(opts, :url)
    GenServer.start_link(__MODULE__, opts, name: {:global, {:relay, url}})
  end

  # Private API

  @impl GenServer
  def init(opts) do
    url = opts |> Keyword.fetch!(:url) |> URI.parse()
    read_only = Keyword.get(opts, :read_only, false)

    notice_handler =
      Keyword.get(opts, :notice_handler, fn msg, url ->
        Logger.error("Notice from #{url}: #{msg}")
      end)

    port =
      case url do
        %URI{scheme: "wss", port: port} -> port || 443
        %URI{scheme: "ws", port: port} -> port || 80
      end

    # Establish WebSocket connection
    {:ok, conn} =
      :gun.open(String.to_charlist(url.host), port, %{
        protocols: [:http],
        tls_opts: [verify: :verify_none]
      })

    {:ok,
     %{
       conn: conn,
       stream: nil,
       url: URI.to_string(url),
       read_only: read_only,
       status: :connecting,
       notice_handler: notice_handler
     }}
  end

  @impl GenServer
  def handle_cast({:send, msg}, state) do
    :gun.ws_send(state.conn, state.stream, {:text, msg})
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:state, _from, state) do
    {:reply, state, state}
  end

  @impl GenServer
  def handle_info({:gun_up, conn, :http}, state) do
    Logger.debug("Connection up #{state.url}")
    stream = :gun.ws_upgrade(conn, URI.parse(state.url).path || "/")
    {:noreply, %{state | conn: conn, stream: stream}}
  end

  def handle_info({:gun_upgrade, _conn, _stream, ["websocket"], _headers}, state) do
    Logger.debug("WebSocket upgraded #{state.url}")
    {:noreply, %{state | status: :open}}
  end

  def handle_info({:gun_response, _conn, _stream, _fin, status, _headers}, state) do
    Logger.warning("Response #{status} #{state.url}")
    {:noreply, state}
  end

  def handle_info({:gun_data, _conn, _stream, _fin, _response}, state) do
    {:noreply, state}
  end

  def handle_info({:gun_down, _conn, :http, :normal, _headers}, state) do
    Logger.warning("HTTP connection down normal #{state.url}")
    {:noreply, %{state | status: :down}}
  end

  def handle_info({:gun_down, _conn, :http, :closed, _headers}, state) do
    Logger.warning("HTTP connection down #{state.url}")
    {:noreply, %{state | status: :down}}
  end

  def handle_info({:gun_down, _conn, :ws, :closed, _headers}, state) do
    Logger.warning("WebSocket connection down #{state.url}")
    {:noreply, %{state | status: :closing}}
  end

  def handle_info({:gun_ws, _conn, _stream, {:text, message}}, state) do
    message
    |> Nostr.Message.parse()
    |> case do
      {:event, sub_id, event} ->
        GenServer.cast({:global, {:subscription, sub_id}}, {event, state.url})

      {:eose, sub_id} ->
        GenServer.cast({:global, {:subscription, sub_id}}, {:eose, state.url})

      {:notice, message} ->
        state.notice_handler.(message, state.url)
    end

    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    :gun.shutdown(state.conn)
  end
end
