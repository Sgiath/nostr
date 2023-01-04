defmodule Nostr.Subscription do
  use GenServer

  require Logger

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: {:global, {:subscription, id}})
  end

  # Private API

  @impl GenServer
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    filters = Keyword.fetch!(opts, :filters)
    relays = Keyword.fetch!(opts, :relays)
    subscribers = Keyword.fetch!(opts, :subscribers)

    {:ok, %{id: id, filters: filters, relays: %{}, events: %{}, subscribers: subscribers}, {:continue, relays}}
  end

  @impl GenServer
  def handle_continue(relays, state) do
    msg =
      state.filters
      |> Nostr.Message.request(state.id)
      |> Nostr.Message.serialize()

    relays =
      relays
      |> Enum.map(fn {url, %{pid: pid}} ->
        GenServer.cast(pid, {:send, msg})

        {url, %{pid: pid, state: :init}}
      end)
      |> Enum.into(%{})

    {:noreply, %{state | relays: relays}}
  end

  @impl GenServer
  def handle_cast({%Nostr.Event{} = event, url}, state) do
    for pid <- state.subscribers do
      send(pid, event)
    end

    {:noreply, put_in(state, [:relays, url, :state], :loading)}
  end

  def handle_cast({:eose, url}, state) do
    Logger.info("End of stream for #{url}")
    {:noreply, put_in(state, [:relays, url, :state], :eose)}
  end

  @impl GenServer
  def handle_call(:close, _from, state) do
    Logger.debug("Closing subscription #{state.id}")

    msg =
      state.id
      |> Nostr.Message.close()
      |> Nostr.Message.serialize()

    for {_url, %{pid: pid}} <- state.relays do
      GenServer.cast(pid, {:send, msg})
    end

    {:reply, :ok, state}
  end
end
