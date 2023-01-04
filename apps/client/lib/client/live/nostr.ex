defmodule Client.Live.Nostr do
  use Client, :live_view

  require Logger

  @impl true
  def mount(_params, _args, socket) do
    Phoenix.PubSub.subscribe(Nostr.PubSub, "events:test")

    {:ok,
     assign(socket, %{
       relays: Nostr.connected_relays(),
       metadata: %{},
       following: [],
       notes: %{},
       events: %{},
       messages: %{}
     })}
  end

  @impl true
  def handle_event("connect", _value, socket) do
    for url <- Client.Config.relays() do
      {:ok, pid} = Nostr.start_child(url)
      state = GenServer.call(pid, :state)
      Phoenix.PubSub.subscribe(Nostr.PubSub, "relays:#{state.url.host}")
    end

    {:noreply, assign(socket, :relays, Nostr.connected_relays())}
  end

  def handle_event("disconnect", _value, socket) do
    for {:undefined, pid, :worker, [_name]} <- DynamicSupervisor.which_children(Nostr) do
      DynamicSupervisor.terminate_child(Nostr, pid)
    end

    {:noreply, assign(socket, :relays, Nostr.connected_relays())}
  end

  def handle_event("request", _value, socket) do
    filter1 = %Nostr.Filter{
      authors: [Client.Config.pubkey()],
      since: ~U[1970-01-01 00:00:00Z]
    }

    filter2 = %Nostr.Filter{
      "#p": [Client.Config.pubkey()],
      since: ~U[1970-01-01 00:00:00Z]
    }

    sub_id = 32 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

    for {:undefined, pid, :worker, [_name]} <- DynamicSupervisor.which_children(Nostr) do
      Task.start(fn -> Nostr.Connection.req(pid, [filter1, filter2], sub_id) end)
      state = GenServer.call(pid, :state)
      Phoenix.PubSub.subscribe(Nostr.PubSub, "events:#{state.url.host}:#{sub_id}")
    end

    {:noreply, assign(socket, :relays, Nostr.connected_relays())}
  end

  @impl true
  # Handle metadata
  def handle_info(%Nostr.Event{kind: 0, content: content}, socket) do
    {:noreply, assign(socket, :metadata, Jason.decode!(content))}
  end

  # Handle note
  def handle_info(%Nostr.Event{id: id, kind: 1} = event, socket) do
    {:noreply, assign(socket, :notes, Map.put(socket.assigns.notes, id, event))}
  end

  # Handle following
  def handle_info(%Nostr.Event{kind: 3, tags: tags}, socket) do
    {:noreply, assign(socket, :following, Enum.map(tags, &elem(&1, 1)))}
  end

  # Handle encrypted message
  def handle_info(
        %Nostr.Event{id: id, pubkey: pubkey, kind: 4, content: content, tags: tags} = event,
        socket
      ) do
    seckey = Client.Config.seckey()
    my_pubkey = Client.Config.pubkey()

    pubkey =
      if pubkey == my_pubkey do
        Enum.find_value(tags, fn
          {:p, pubkey, []} -> pubkey
          _ -> false
        end)
      else
        pubkey
      end

    event =
      Map.put(event, :content, %{
        cipher_text: content,
        plain_text: Nostr.Crypto.decrypt(content, seckey, pubkey)
      })

    {:noreply, assign(socket, :messages, Map.put(socket.assigns.messages, id, event))}
  end

  # Handle other events
  def handle_info(%Nostr.Event{id: id} = event, socket) do
    {:noreply, assign(socket, :events, Map.put(socket.assigns.events, id, event))}
  end

  # Handle end of stream events
  def handle_info(:eose, socket) do
    {:noreply, socket}
  end

  # Handle end of stream events
  def handle_info({:notice, message, server}, socket) do
    Logger.warning("Received notice from server #{server}: #{message}")
    {:noreply, socket}
  end
end
