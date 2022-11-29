defmodule FTC.Server do
    @moduledoc """
    A general implementation of a server. Could contain network
    function and replicas (for other NFs), and forwarder and buffer.
    """
    alias __MODULE__

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
    @spec new_configuration(atom(), atom(), non_neg_integer(), non_neg_integer()) :: %Server{}
    def new_configuration(id, orchestrator, heartbeat_timeout, nop_timeout) do
        %Server{
            id: id,
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
            _n = Emulation.cancel_timer(state.nop_timer)
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
        orch = state.orchestrator
        receive do
            # Control message from orchestrator
            {^orch,
             %FTC.NewInstance{
                nf_name: nf,
                prev_hop: prev_hop,
                next_hop: next_hop,
                num_of_replications: num_of_replications,
                replica_storage: replica_storage,
                rep_group: rep_group,
                is_first: is_first,
                is_last: is_last
             }} ->
                IO.puts("#{whoami()}(server): NewInstance received, turn to nf_node (#{nf})")
                state = %{state | 
                            nf_name: nf,
                            nf_state: hd(replica_storage),
                            prev_hop: prev_hop,
                            next_hop: next_hop,
                            num_of_replications: num_of_replications,
                            replica_storage: tl(replica_storage),
                            rep_group: rep_group,
                        }
                state = add_forwarder(state, is_first)
                state = add_buffer(state, is_last)
                become_nf_node(state)

            # Messages for testing
            {sender, {:master_get, key}} ->
                # IO.puts("#{whoami()}(server): master_get received, return #{key}")
                send(sender, Map.get(state, key))
                server(state)
            
            # Messages from clients
            {sender, %FTC.Message{gnb: _, nonce: nonce, header: _, payload: _}} ->
                # should redirect the client to the orchestrator to
                # ask for the first node inside the chain
                send(sender, {:not_entry, nonce})
                server(state)

            # Default entry
            _ ->
                server(state)
        end
    end
    
    @spec become_nf_node(%Server{}) :: no_return()
    def become_nf_node(state) do
        state = %{state | in_use: true}
        send(state.orchestrator, :heartbeat)
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
                # IO.puts("Insert a rule in replica: #{update.key}, #{update.value}")
                Map.put_new(storage, update.key, update.value)

            "delete" ->
                # IO.puts("Delete a rule in replica: #{update.key}, #{update.value}")
                Map.delete(storage, update.key)
            
            "modify" ->
                # IO.puts("Modify a rule in replica: #{update.key}, #{update.value}")
                Map.put(storage, update.key, update.value)
    
            _ ->
                # IO.puts("Not valid operation #{update.action} on storage state update")
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
            storage
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
            {_nonce, one_log} = hd(updates)
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
    @spec nf_process(%Server{}, %FTC.Message{}) :: {%Server{}, %FTC.Message{}, list(%FTC.StateUpdate{})}
    def nf_process(state, msg) do
        if msg.header.fail_bit == 0 do
            case state.nf_name do
                :amf ->
                    # check ue registration status
                    ue_id = msg.header.ue
                    reg_cnt = Map.get(state.nf_state, ue_id)
                    case reg_cnt do
                        nil ->
                            # IO.puts("No record yet. Update to register.")
                            state = %{state | nf_state: Map.put(state.nf_state, ue_id, 1)}
                            {state, msg, [FTC.StateUpdate.new("insert", ue_id, 1)]}  
                        _ ->
                            # IO.puts("Update de-registered to register.")
                            state = %{state | nf_state: Map.put(state.nf_state, ue_id, reg_cnt + 1)}
                            {state, msg, [FTC.StateUpdate.new("modify", ue_id, reg_cnt + 1)]}
                    end

                :ausf ->
                    # check ue authentication
                    ue_id = msg.header.ue
                    subscriber = msg.header.sub
                    sb_log = Map.get(state.nf_state, ue_id)
                    case sb_log do
                        {^subscriber, 0} ->
                            IO.puts("Successfully authenticate. Update authentication status.")
                            state = %{state | nf_state: Map.put(state.nf_state, ue_id, {subscriber, 1})}
                            {state, msg, [FTC.StateUpdate.new("modify", ue_id, 1)]}

                        {^subscriber, 1} ->
                            IO.puts("Successfully authenticate.")
                            {state, msg, []}

                        _ ->
                            IO.puts("No subscriber #{subscriber} support. Fail to authenticate.")
                            msg = %{msg | header: %{msg.header | fail_bit: 1}}
                            {state, msg, []}
                    end
                    
                :smf ->
                    # session management
                    IO.puts("SMF processing")
                    ue_id = msg.header.ue
                    subscriber = msg.header.sub
                    ex_src_ip = Map.get(state.nf_state, ue_id)
                    if ex_src_ip != nil do
                        IO.puts("Already allocated an IP.")
                        msg = %{msg | header: %{msg.header | src_ip: ex_src_ip}}
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
                                state_update_list = [FTC.StateUpdate.new("modify", "subscriber", current_max_ip + 1), 
                                                    FTC.StateUpdate.new("insert", ue_id, allocated_ip)]
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
                                state_update_list = [FTC.StateUpdate.new("modify", "subscriber", current_max_ip + 1), 
                                                    FTC.StateUpdate.new("insert", ue_id, allocated_ip)]
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
                                state_update_list = [FTC.StateUpdate.new("modify", "subscriber", current_max_ip + 1), 
                                                    FTC.StateUpdate.new("insert", ue_id, allocated_ip)]
                                {state, msg, state_update_list} 

                            _ ->
                                IO.puts("No subscriber support. Fail to allocate IP.")
                                msg = %{msg | header: %{msg.header | fail_bit: 1}}
                                {state, msg, []} 
                        end
                    end

                :upf ->
                    # traffic statistic
                    ue_id = msg.header.ue
                    src_ip = msg.header.src_ip
                    # IO.puts("Update total number of packets from src_ip.")
                    cnt = Map.get(state.nf_state, ue_id)
                    if cnt == nil do
                        updated_nf_state = Map.put(state.nf_state, src_ip, 1)
                        state = %{state | nf_state: updated_nf_state}
                        {state, msg, [FTC.StateUpdate.new("insert", src_ip, 1)]}
                    else
                        updated_nf_state = Map.put(state.nf_state, src_ip, cnt + 1)
                        state = %{state | nf_state: updated_nf_state}
                        {state, msg, [FTC.StateUpdate.new("modify", src_ip, cnt + 1)]}
                    end
            end 
        else
            {state, msg, []}
        end 
    
    end

    @spec buffer_response(%Server{}, map()) :: %Server{}
    def buffer_response(state, commit_vectors) do
        latest_nonce = Enum.min(Map.values(commit_vectors))
        Enum.map(commit_vectors, fn {nf, v} -> IO.puts("#{nf}: #{v}") end)
        IO.puts(latest_nonce)
        repliable = Enum.filter(Map.keys(state.buffer), fn x -> x <= latest_nonce end)
        Enum.map(repliable, fn x ->
            msg = Map.get(state.buffer, x)
            send(msg.gnb, {:done, msg.nonce, msg.header})
        end)
        state = %{state | buffer: Map.drop(state.buffer, repliable)}
        state
    end

    @spec nf_node(%Server{}, any()) :: no_return()
    def nf_node(state, extra_state) do
        orch = state.orchestrator
        p_hop = state.prev_hop
        receive do
            # Control message from orchestrator
            {^orch, :terminate} -> 
                IO.puts("#{whoami()}(nf_node, #{state.nf_name}): terminate received, turn to server")
                become_server(state)

            {^orch, :pause} ->
                IO.puts("#{whoami()}(nf_node, #{state.nf_name}): pause received, turn to paused_node")
                paused_node(state, %{prev_hop: state.prev_hop, next_hop: state.next_hop, message_list: []})

            # Messages for testing
            {sender, {:master_get, key}} ->
                # IO.puts("#{whoami()}(nf_node, #{state.nf_name}): master_get received, return #{key}")
                send(sender, Map.get(state, key))
                nf_node(state, extra_state)
            
            {sender, :master_terminate} ->
                IO.puts("#{whoami()}(nf_node, #{state.nf_name}): master_terminate received, turn to server")
                become_server(state)

            # Heartbeat timer, send a heartbeat to the orchestrator
            :timer_heartbeat ->
                send(orch, :heartbeat)
                reset_heartbeat_timer(state)
                nf_node(state, extra_state)
            
            # Nop timer, only received if it is the first nf in the chain and 
            # no messages are received in a while
            :timer_nop ->
                state = reset_nop_timer(state)
                if Enum.empty?(state.forwarder) do
                    nf_node(state, extra_state)
                else
                    IO.puts("#{whoami()}(nf_node, #{state.nf_name}): timer_nop received, send empty to #{state.next_hop}")
                    {{piggyback_logs, commit_vectors}, new_forwarder} = List.pop_at(state.forwarder, 0)
                    state = %{state | forwarder: new_forwarder}

                    piggyback_logs = List.insert_at(piggyback_logs, 0, {nil, []})
                    send(state.next_hop, {:empty, piggyback_logs, commit_vectors})
                    nf_node(state, extra_state)
                end

            # Message from previous hop
            {^p_hop, {:empty, piggyback_logs, commit_vectors}} ->
                IO.puts("#{whoami()}(nf_node, #{state.nf_name}): empty received from #{p_hop}, forward to #{state.next_hop}")
                # update replica
                updated_storage = loop_update_replica(state.replica_storage, piggyback_logs)
                state = %{state | replica_storage: updated_storage}
                # update commit_vectors
                {nonce, _} = Enum.at(piggyback_logs, -1)
                commit_vectors = if(nonce != nil, do: Map.put(commit_vectors, state.rep_group, nonce), else: commit_vectors)
                # update piggyback
                piggyback_logs = List.delete_at(piggyback_logs, -1)
                piggyback_logs = List.insert_at(piggyback_logs, 0, {nil, []})

                if state.is_last do # put message in the buffer and send to the forwarder
                    state = buffer_response(state, commit_vectors)
                    nf_node(state, extra_state)
                else # send to the next nf in the chain
                    send(state.next_hop, {:empty, piggyback_logs, commit_vectors})
                    nf_node(state, extra_state)
                end

            {^p_hop, {:from_buffer, piggyback_logs, commit_vectors}} ->
                IO.puts("#{whoami()}(nf_node, #{state.nf_name}): from_buffer received from #{p_hop}, put in forwarder")
                # update replica
                updated_storage = loop_update_replica(state.replica_storage, piggyback_logs)
                state = %{state | replica_storage: updated_storage}
                # update commit_vectors
                {nonce, _} = Enum.at(piggyback_logs, -1)
                commit_vectors = Map.put(commit_vectors, state.rep_group, nonce)
                # update piggyback
                piggyback_logs = List.delete_at(piggyback_logs, -1)

                state = %{state | forwarder: state.forwarder ++ [{piggyback_logs, commit_vectors}]}
                nf_node(state, extra_state)

            {^p_hop, {msg, piggyback_logs, commit_vectors}} -> 
                IO.puts("#{whoami()}(nf_node, #{state.nf_name}): msg received from #{p_hop}, forward to #{state.next_hop}")
                # update replica
                updated_storage = loop_update_replica(state.replica_storage, piggyback_logs)
                state = %{state | replica_storage: updated_storage}
                # update commit_vectors
                {nonce, _} = Enum.at(piggyback_logs, -1)
                commit_vectors = if(nonce != nil, do: Map.put(commit_vectors, state.rep_group, nonce), else: commit_vectors)
                # nf process logic and update primary state
                {state, msg, updates} = nf_process(state, msg)
                # update piggyback
                piggyback_logs = List.delete_at(piggyback_logs, -1)
                piggyback_logs = List.insert_at(piggyback_logs, 0, {msg.nonce, updates})

                if state.is_last do # put message in the buffer and send to the forwarder
                    state = %{state | buffer: Map.put(state.buffer, msg.nonce, msg)}
                    state = buffer_response(state, commit_vectors)
                    # send the piggyback and commit_vectors back to the first node
                    send(state.next_hop, {:from_buffer, piggyback_logs, commit_vectors})
                    nf_node(state, extra_state)
                else # send to the next nf in the chain
                    send(state.next_hop, {msg, piggyback_logs, commit_vectors})
                    nf_node(state, extra_state)
                end
            
            # Not entry messages to be ignored
            {sender, {:not_entry, _}} ->
                nf_node(state, extra_state)

            # Messages from ues
            {sender, msg} ->
                if not state.is_first do
                    IO.puts("#{whoami()}(nf_node, #{state.nf_name}): msg received from #{sender}, not entry; prev_hop: #{state.prev_hop}")
                    send(sender, {:not_entry, msg.nonce})
                    nf_node(state, extra_state)
                else
                    # this is the first nf node
                    IO.puts("#{whoami()}(nf_node, #{state.nf_name}): msg received from #{sender}, proceed and send to #{state.next_hop}")
                    default = {List.duplicate({nil, []}, state.num_of_replications - 2), Map.new([{state.rep_group, 0}])}
                    {{piggyback_logs, commit_vectors}, new_forwarder} = List.pop_at(state.forwarder, 0, default)
                    state = %{state | forwarder: new_forwarder}
                    state = reset_nop_timer(state)
                    
                    # nf process logic and update primary state
                    {state, msg, updates} = nf_process(state, msg)
                    piggyback_logs = List.insert_at(piggyback_logs, 0, {msg.nonce, updates})
                    send(state.next_hop, {msg, piggyback_logs, commit_vectors})
                    nf_node(state, extra_state)
                end

            # Default entry
            _ ->
                nf_node(state, extra_state)
        end
    end

    @doc """
    If there are some more messages coming from prev_hop, they are stored in the extra state
    """
    @spec paused_node(%Server{}, map()) :: no_return()
    def paused_node(state, extra_state) do
        orch = state.orchestrator
        receive do
            # Control message from orchestrator
            {^orch, :terminate} ->
                IO.puts("#{whoami()}(paused_node, #{state.nf_name}): terminate received, turn to server") 
                become_server(state)

            {^orch, :resume} ->
                IO.puts("#{whoami()}(paused_node, #{state.nf_name}): resume received, turn to nf_node")
                back_to_nf_node(state, extra_state)

            {^orch, :get_state} ->
                IO.puts("#{whoami()}(paused_node, #{state.nf_name}): get_state received, return state") 
                send(
                    orch,
                    FTC.StateResponse.new(
                        state.id,
                        [state.nf_state | state.replica_storage]
                    )
                )
                paused_node(state, extra_state)
            
            {^orch, %FTC.ChainUpdate{
                prev_hop: prev_hop,
                next_hop: next_hop
             }} ->
                IO.puts("#{whoami()}(paused_node): ChainUpdate received, update prev/next hop") 
                extra_state = %{extra_state | prev_hop: prev_hop, next_hop: next_hop}
                paused_node(state, extra_state)

            # Messages for testing
            {sender, {:master_get, key}} ->
                # IO.puts("#{whoami()}(paused_node): master_get received, return #{key}")
                send(sender, Map.get(state, key))
                paused_node(state, extra_state)
            
            {sender, {:master_get_extra, key}} ->
                # IO.puts("#{whoami()}(paused_node): master_get_extra received, return #{key}")
                send(sender, Map.get(extra_state, key))
                paused_node(state, extra_state)

            # Heartbeat timer, send a heartbeat to the orchestrator
            :timer_heartbeat ->
                send(orch, :heartbeat)
                reset_heartbeat_timer(state)
                paused_node(state, extra_state)
            
            # Nop timer, in paused mode, just ignore it and reset
            :timer_nop ->
                state = reset_nop_timer(state)
                paused_node(state, extra_state)

            # Not entry messages to be ignored
            {sender, {:not_entry, _}} ->
                paused_node(state, extra_state)

            # Messages need to be stored
            {sender, msg} ->
                extra_state = %{extra_state | message_list: extra_state.message_list ++ [{sender, msg}]}
                paused_node(state, extra_state)

            # Default entry
            _ ->
                paused_node(state, extra_state)
        end
    end

    @doc """
    Resume the service, send the stored messages
    """
    @spec back_to_nf_node(%Server{}, map()) :: no_return()
    def back_to_nf_node(state, extra_state) do
        p_hop = state.prev_hop
        if length(extra_state.message_list) == 0 do
            state = %{state | prev_hop: extra_state.prev_hop, next_hop: extra_state.next_hop}
            nf_node(state, nil)
        else
            next_msg = hd(extra_state.message_list)
            extra_state = %{extra_state | message_list: tl(extra_state.message_list)}
            case next_msg do
                # Message from previous hop
                {^p_hop, {:empty, piggyback_logs, commit_vectors}} ->
                    # update replica
                    updated_storage = loop_update_replica(state.replica_storage, piggyback_logs)
                    state = %{state | replica_storage: updated_storage}
                    # update commit_vectors
                    {nonce, _} = Enum.at(piggyback_logs, -1)
                    commit_vectors = if(nonce != nil, do: Map.put(commit_vectors, state.rep_group, nonce), else: commit_vectors)
                    # update piggyback
                    piggyback_logs = List.delete_at(piggyback_logs, -1)
                    piggyback_logs = List.insert_at(piggyback_logs, 0, {nil, []})

                    if state.is_last do # put message in the buffer and send to the forwarder
                        state = buffer_response(state, commit_vectors)
                        back_to_nf_node(state, extra_state)
                    else # send to the next nf in the chain
                        send(extra_state.next_hop, {:empty, piggyback_logs, commit_vectors})
                        back_to_nf_node(state, extra_state)
                    end

                {^p_hop, {:from_buffer, piggyback_logs, commit_vectors}} ->
                    # update replica
                    updated_storage = loop_update_replica(state.replica_storage, piggyback_logs)
                    state = %{state | replica_storage: updated_storage}
                    # update commit_vectors
                    {nonce, _} = Enum.at(piggyback_logs, -1)
                    commit_vectors = Map.put(commit_vectors, state.rep_group, nonce)
                    # update piggyback
                    piggyback_logs = List.delete_at(piggyback_logs, -1)

                    state = %{state | forwarder: state.forwarder ++ [{piggyback_logs, commit_vectors}]}
                    back_to_nf_node(state, extra_state)

                {^p_hop, {msg, piggyback_logs, commit_vectors}} -> 
                    # update replica
                    updated_storage = loop_update_replica(state.replica_storage, piggyback_logs)
                    state = %{state | replica_storage: updated_storage}
                    # nf process logic and update primary state
                    {state, msg, updates} = nf_process(state, msg)
                    # update commit_vectors
                    {nonce, _} = Enum.at(piggyback_logs, -1)
                    commit_vectors = if(nonce != nil, do: Map.put(commit_vectors, state.rep_group, nonce), else: commit_vectors)
                    # update piggyback
                    piggyback_logs = List.delete_at(piggyback_logs, -1)
                    piggyback_logs = List.insert_at(piggyback_logs, 0, {msg.nonce, updates})

                    if state.is_last do # put message in the buffer and send to the forwarder
                        state = %{state | buffer: Map.put(state.buffer, msg.nonce, msg)}
                        state = buffer_response(state, commit_vectors)
                        # send the piggyback and commit_vectors back to the first node
                        send(extra_state.next_hop, {:from_buffer, piggyback_logs, commit_vectors})
                        back_to_nf_node(state, extra_state)
                    else # send to the next nf in the chain
                        send(extra_state.next_hop, {msg, piggyback_logs, commit_vectors})
                        back_to_nf_node(state, extra_state)
                    end

                # Messages from clients
                {sender, msg} ->
                    if not state.is_first do
                        send(sender, {:not_entry, msg.nonce})
                        back_to_nf_node(state, extra_state)
                    else
                        # this is the first nf node
                        default = {List.duplicate({nil, []}, state.num_of_replications - 2), Map.new([{state.rep_group, 0}])}
                        {{piggyback_logs, commit_vectors}, new_forwarder} = List.pop_at(state.forwarder, 0, default)
                        state = %{state | forwarder: new_forwarder}
                        state = reset_nop_timer(state)
                        
                        # nf process logic and update primary state
                        {state, msg, updates} = nf_process(state, msg)
                        piggyback_logs = List.insert_at(piggyback_logs, 0, {msg.nonce, updates})
                        send(extra_state.next_hop, {msg, piggyback_logs, commit_vectors})
                        back_to_nf_node(state, extra_state)
                    end
                
                _ ->
                    back_to_nf_node(state, extra_state)
            end
        end
    end
end