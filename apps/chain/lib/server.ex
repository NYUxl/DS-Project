defmodule Server do
    @moduledoc """
    A general implementation of a server. Could contain network
    function and replicas (for other NFs), and forwarder and buffer.
    """

    # Shouldn't need to spawn anything from this module
    import Emulation, only: [send: 2, timer: 1, timer: 2, now: 0, whoami: 0]

    import Kernel,
        except: [spawn: 3, spawn: 1, spawn_link: 1, spawn_link: 3, send: 2]

    require Fuzzers

    # General structure of a server
    defstruct(
        # basic information
        id: nil,
        orchestrator: nil,
        in_use: nil,
        heartbeat_timeout: nil,
        # special timeout if this server contains a forwarder
        nop_timeout: nil,
        nop_timer: nil,
        # message buffer for reliable transmission
        # m_buf: nil, # TODO: whether to add this?
        # state for the own NF
        nf_name: nil,
        nf_state: nil,
        # information for the NF chain
        prev_hop: nil,
        next_hop: nil,
        num_of_replications: nil,
        replica_storage: nil,
        rep_group: nil,
        # forwarder and buffer
        is_first: nil,
        is_last: nil,
        forwarder: nil, # list of following piggyback headers
        buffer: nil # list of waiting packets
    )

    @doc """
    Create a new server, and can turn to different nf later
    """
    @spec new_configuration(atom(), non_neg_integer(), non_neg_integer()) :: %Server{}
    def new_configuration(orchestrator, heartbeat_timeout, nop_timeout) do
        %Server{
            id: whoami(),
            orchestrator: orchestrator,
            in_use: false,
            heartbeat_timeout: heartbeat_timeout,
            nop_timeout: nop_timeout,
            nop_timer: nil,
            nf_name: nil,
            nf_state: nil,
            prev_hop: nil,
            next_hop: nil,
            num_of_replications: nil,
            replica_storage: nil,
            rep_group: nil,
            is_first: nil,
            is_last: nil,
            forwarder: nil,
            buffer: nil
        }
    end

    @spec reset_heartbeat_timer(%Server{}) :: no_return()
    def reset_heartbeat_timer(state) do
        Emulation.timer(state.heartbeat_timeout, :timer_heartbeat)
    end

    @spec reset_nop_timer(%Server{}) :: %Server{}
    def reset_nop_timer(state) do
        if state.nop_timer != nil do
            n = Emulation.cancel_timer(state.nop_timer)
        end
        %{state | nop_timer: Emulation.timer(state.nop_timeout, :timer_nop)}
    end

    @spec add_forwarder(%Server{}, boolean()) :: %Server{}
    def add_forwarder(state, is_first) do
        state = %{state | is_first: is_first}
        if is_first do
            state = %{state | forwarder: []}
            state = reset_nop_timer(state)
            state
        else
            state
        end
    end

    @spec add_buffer(%Server{}, boolean()) :: %Server{}
    def add_buffer(state, is_last) do
        state = %{state | is_last: is_last}
        if is_last do
            %{state | buffer: %{}}
        else
            state
        end
    end

    @doc """
    Called when server initialized or when some failure occurs
    """
    @spec become_server(%Server{}) :: no_return()
    def become_server(state) do 
        state = %{state | in_use: false}
        server(state)
    end

    @spec server(%Server{}) :: no_return()
    def server(state) do
        receive do
            # Control message from orchestrator
            {^state.orchestrator,
             %Server.NewInstance{
                nf_name: nf,
                prev_hop: prev_hop,
                next_hop: next_hop,
                num_of_replications: num_of_replications,
                replica_storage: replica_storage,
                rep_group: rep_group,
                is_first: is_first,
                is_last: is_last
             }} ->
                state = %{state | 
                            nf_name: nf,
                            nf_state: hd(replica_storage),
                            prev_hop: prev_hop,
                            next_hop: next_hop,
                            num_of_replications: num_of_replications,
                            replica_storage: replica_storage,
                            rep_group: rep_group,
                        }
                state = add_forwarder(state, is_first)
                state = add_buffer(state, is_last)
                become_nf_node(state)
            
            # Messages from clients
            {sender, message} ->
                # should redirect the client to the orchestrator to
                # ask for the first node inside the chain
                send(sender, {:not_entry, message})

            # Messages for testing

            # Default entry
            _ ->
                server(state)
        end
    end
    
    @spec become_nf_node(%Server{}) :: no_return()
    def become_nf_node(state) do
        state = %{state | in_use: true}
        reset_heartbeat_timer(state)
        nf_node(state, nil)
    end
    
    @doc """
    Update replica's states
    """
    @spec update_one_entry(map(), map()) :: map()
    def update_one_entry(storage, update) do
        case update.action do
            "insert" -> 
                Map.put(storage, update.key, update.value)
                IO.puts("Insert a rule in replica")
            "delete" ->
                Map.delete(storage, update.key)
                IO.puts("Delete a rule in replica")
            "modify" ->
                %{storage | update.key: update.value}
                IO.puts("Modify a rule in replica")
            _ ->
                IO.puts("Not valid operation #{update.action} on storage state update")
        end
    end


    @doc """
    Update replica's states
    storage: nf replciate state
    update: list of state update requests
    """
    @spec update_replica(map(), list(map())) :: map()
    def update_replica(storage, updates) do
        if length(updates) == 0 do
            storage
        else
            storage = Enum.reduce(updates, storage, fn up, acc -> update_one_entry(acc, up) end)
        end
    end

    @doc """
    For loop to update the replica's states
    """
    @spec doing_loop_update(list(map()), list(), list(map())) :: list(map())
    def doing_loop_update(storages, updates, ret) do
        if length(updates) == 0 do
            ret
        else
            {nonce, one_log} = hd(updates)
            ret = [update_replica(hd(storages), one_log) | ret]
            doing_loop_update(tl(storages), tl(updates), ret)
        end
    end

    @doc """
    Call this to recursively update the nf replicas
    """
    @spec loop_update_replica(list(map()), list()) :: list(map())
    def loop_update_replica(storages, updates) do
        updated_storages = doing_loop_update(storages, updates, [])
        Enum.reverse(updated_storages)
    end

    @doc """
    The NF processes the incoming message and update its own state
    1: registered
    0: de-registered
    """
    @spec nf_process(atom(), map(), non_neg_integer()) :: {%Server{}, %Message{}, list(%StateUpdate{})}
    def nf_process(state, msg)
        case state.nf_name do
            :amf ->
                # check ue registration status
                ue_id = msg.header.ue
                reg_status_log = Map.get(state.nf_state, ue_id)
                case reg_status_log do
                    nil ->
                        IO.puts("No record. Update to register.")
                        state = %{state | nf_state: Map.put(state.nf_state, ue_id, 1)}
                        {state, msg, [%StateUpdate{action: "insert", key: ue_id, value: 1}]}
                        # TODO: send pkt
                    0 ->
                        IO.puts("Update de-registered to register.")
                        state = %{state | nf_state:Map.put(state.nf_state, ue_id, 1)}
                        {state, msg, [%StateUpdate{action: "modify", key: ue_id, value: 1}]}
                        # TODO: send pkt
                    1 -> 
                        IO.puts("Already registered.")
                        {state, msg, []}
                        # TODO: send pkt
                    _ ->
                        IO.puts("No #{ue_id} registration status.")
                        {state, msg, []}
                        # TODO: send pkt
                end

            :ausf ->
                # check ue authentication
                ue_id = msg.header.ue
                subscriber = msg.header.sb
                sb_log = Map.get(state.nf_state, ue_id)
                case sb_log do
                    {subscriber, 0} ->
                        IO.puts("Successfully authenticate. Update authentication status.")
                        Map.put(state.nf_state, ue_id, {subscriber, 1})
                        {state, msg, [%StateUpdate{action: "modify", key: ue_id, value: 1}]}
                    {subscriber, 1} ->
                        IO.puts("Successfully authenticate.")
                        {state, msg, []}
                    _ ->
                        IO.puts("No subscriber support. Fail to authenticate.")
                        {state, msg, []}
                end
                
            :smf ->
                # session management
                ue_id = msg.header.ue
                subscriber = msg.header.sb
                if Map.get(state.nf_state, ue_id) != nil do
                    IO.puts("Already allocated an IP.")
                    {state, msg, []}
                else
                    case subscriber do
                        "verizon" ->
                            IO.puts("IP allocate for verizion user equipment.")
                            current_max_ip = Map.get(state.nf_state, subscriber)
                            # update ip in msg header
                            allocated_ip = "168.168.168." <> to_string(current_max_ip + 1)
                            updated_hd = %{msg.header | src_ip: allocated_ip}
                            msg = %{msg | header: updated_hd}
                            # update nf_state
                            updated_nf_state = Map.put(state.nf_state, ue_id, allocated_ip)
                            updated_nf_state = Map.put(updated_nf_state, subscriber, current_max_ip + 1)
                            state = %{state | nf_state: updated_nf_state}
                            # return state_update
                            state_update_list = [%StateUpdate{action: "modify", key: "subscriber", value: current_max_ip + 1}, 
                                                %StateUpdate{action: "insert", key: ue_id, value: allocated_ip}]
                            {state, msg, state_update_list}
                        "mint" ->
                            IO.puts("IP allocate for mint equipment.")
                            current_max_ip = Map.get(state.nf_state, subscriber)
                            # update ip in msg header
                            allocated_ip = "168.178.178." <> to_string(current_max_ip + 1)
                            updated_hd = %{msg.header | src_ip: allocated_ip}
                            msg = %{msg | header: updated_hd}
                            # update nf_state
                            updated_nf_state = Map.put(state.nf_state, ue_id, allocated_ip)
                            updated_nf_state = Map.put(updated_nf_state, subscriber, current_max_ip + 1)
                            state = %{state | nf_state: updated_nf_state}
                            # return state_update
                            state_update_list = [%StateUpdate{action: "modify", key: "subscriber", value: current_max_ip + 1}, 
                                                %StateUpdate{action: "insert", key: ue_id, value: allocated_ip}]
                            {state, msg, state_update_list}
                        "at&t" ->
                            IO.puts("IP allocate for at&t equipment.")
                            current_max_ip = Map.get(state.nf_state, subscriber)
                            # update ip in msg header
                            allocated_ip = "168.188.188." <> to_string(current_max_ip + 1)
                            updated_hd = %{msg.header | src_ip: allocated_ip}
                            msg = %{msg | header: updated_hd}
                            # update nf_state
                            updated_nf_state = Map.put(state.nf_state, ue_id, allocated_ip)
                            updated_nf_state = Map.put(updated_nf_state, subscriber, current_max_ip + 1)
                            state = %{state | nf_state: updated_nf_state}
                            # return state_update
                            state_update_list = [%StateUpdate{action: "modify", key: "subscriber", value: current_max_ip + 1}, 
                                                %StateUpdate{action: "insert", key: ue_id, value: allocated_ip}]
                            {state, msg, state_update_list} 
                        _ ->
                            IO.puts("No subscriber support. Fail to allocate IP.")
                    end

                end
            :upf ->
                # traffic statistic
                src_ip = msg.header.src_ip
                IO.puts("Update total number of packets from src_ip.")
                cnt = Map.get(state.nf_state, ue_id)
                if cnt == nil do
                    updated_nf_state = Map.put(state.nf_state, src_ip, 1)
                    {state, msg, [%StateUpdate{action: "insert", key: src_ip, value: 1}]}
                else
                    updated_nf_state = Map.put(state.nf_state, src_ip, cnt + 1)
                    {state, msg, [%StateUpdate{action: "modify", key: src_ip, value: cnt + 1}]}
                end
        end  
    
    end

    @spec buffer_response(%Server{}, map()) :: 

    @spec nf_node(%Server{}, any()) :: no_return()
    def nf_node(state, extra_state) do
        receive do
            # Control message from orchestrator
            {^state.orchestrator, :terminate} -> 
                become_server(state)

            {^state.orchestrator, :pause} ->
                paused_node(state, [])

            # Heartbeat timer, send a heartbeat to the orchestrator
            :timer_heartbeat ->
                send(orchestrator, :heartbeat)
                reset_heartbeat_timer(state)
                nf_node(state, extra_state)
            
            # Nop timer, only received if it is the first nf in the chain and 
            # no messages are received in a while

            # Message from previous hop
            {^state.prev_hop, {:empty, piggyback_logs, commit_vectors}} ->

            {^state.prev_hop, {:from_buffer, piggyback_logs, commit_vectors}} ->


            {^state.prev_hop, {msg, piggyback_logs, commit_vectors}} -> 
                # update replica
                updated_storage = loop_update_replica(state.replica_storage, piggyback_logs)
                state = %{state | replica_storage: updated_storage}
                # nf process logic and update primary state
                {state, msg, updates} = nf_process(state, msg)
                # update commit_vectors
                {nonce, _} = Enum.at(piggyback_logs, -1)
                commit_vectors = Map.put(commit_vectors, state.rep_group, nonce)
                # update piggyback
                piggyback_logs = List.delete_at(piggyback_logs, -1)
                piggyback_logs = List.insert_at(piggyback_logs, 0, {msg.nonce, updates})

                if state.is_last do # put message in the buffer and send to the forwarder
                    state = %{state | buffer: Map.put(state.buffer, msg.nonce, msg)}
                    state = 
                    nf_node(state, extra_state)
                else # send to the next nf in the chain
                    send(state.next_hop, {msg, piggyback_logs, commit_vectors})
                    nf_node(state, extra_state)
                end

            # Messages from clients
            {sender, msg} ->
                if not state.is_first do
                    send(sender, {:not_entry, msg.nonce})
                    nf_node(state, extra_state)
                else
                    # this is the first nf node
                    {{piggyback_logs, commit_vectors}, new_forwarder} = List.pop(state.forwarder, 0, {[], %{}})
                    state = %{state | forwarder: new_forwarder}
                    state = reset_nop_timer(state)
                    send(state.next_hop, {msg, piggyback_logs, commit_vectors})
                    nf_node(state, extra_state)
                end

            # Messages for testing

            # Default entry
            _ ->
                nf_node(state, extra_state)
        end
    end

    @doc """
    If there are some more messages coming from prev_hop, they are stored in the extra state
    """
    @spec paused_node(%Server{}, list()) :: no_return()
    def paused_node(state, extra_state) do
        receive do
            # Control message from orchestrator
            {^state.orchestrator, :terminate} -> 
                become_server(state)

            {^state.orchestrator, :resume} ->
                back_to_nf_node(state, extra_state)

            {^state.orchestrator, :get_state} ->
                send(
                    state.orchestrator,
                    Server.StateResponse.new(
                        state.id,
                        state.replica_storage
                    )
                )
                paused_node(state, extra_state)

            # Heartbeat timer, send a heartbeat to the orchestrator
            :timer_heartbeat ->
                send(orchestrator, :heartbeat)
                reset_heartbeat_timer(state)
                paused_node(state, extra_state)
            
            # Nop timer, only received if it is the first nf in the chain and 
            # no messages are received in a while

            # Message from previous hop
            {^prev_hop, {msg, piggyback_logs, commit_vectors}} -> 
                # update replica
                updated = loop_update_replica(state.replica_storage, piggyback_logs)
                state = %{state | replica_storage: updated_storage}
                # nf process logic and update primary state
                {state, msg, updates} = nf_process(state, msg)
                # update piggyback
                piggyback_logs = List.delete_at(piggyback_logs, -1)
                piggyback_logs = List.insert_at(piggyback_logs, 0, updates)
                # TODO: commit_vectors
                # send to the next nf in the chain
                send(next_hop, {msg, piggyback_logs, commit_vectors})

            # Messages from clients
            {sender, {msg, piggyback_logs, commit_vectors}} ->
                # forwarder logic here


            # Messages for testing

            # Default entry
            _ ->
                nf_node(state, extra_state)
        end
    end

    @doc """
    Resume the service, send the stored messages
    """
    @spec back_to_nf_node(%Server{}, list()) :: no_return()
    def back_to_nf_node(state, extra_state) do
        messages = Enum.reverse(extra_state)
        # TODO: to deal with the messages and send them out
    end
end