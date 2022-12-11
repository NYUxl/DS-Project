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
            %{state | forwarder: []}
        else
            state
        end
    end

    @spec add_buffer(%Server{}, boolean()) :: %Server{}
    def add_buffer(state, is_last) do
        state = %{state | is_last: is_last}
        if is_last do
            %{state | buffer: []}
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
    @spec update_replica(map(any()), map(any())) :: map(any())
    def update_replica(storage, update) do
        if update == nil do
            storage
        else
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
    end

    @doc """
    For loop to update the replica's states
    """
    @spec doing_loop_update(list(map()), list(map()), list(map())) :: list(map())
    def doing_loop_update(storages, updates, ret) do
        if length(updates) == 0 do
            ret
        else
            ret = [update_replica(hd(storages), hd(updates)) | ret]
            doing_loop_update(tl(storages), tl(updates), ret)
        end
    end

    @doc """
    Call this to recursively update the nf replicas
    """
    @spec loop_update_replica(list(map()), list(map())) :: list(map())
    def loop_update_replica(storages, updates) do
        updated_storages = doing_loop_update(storages, updates, [])
        Enum.reverse(updated_storages)
    end

    @doc """
    The NF processes the incoming message and update its own state
    1: registered
    0: de-registered
    """
    @spec nf_process(:atom(), map(any()), non_neg_integer()) :: %Server{}
    def nf_process(state, msg)
        ue_id = Map.get(state.nf_state, msg.header.ue)
        case state.nf_name do
            :amf ->
                # check ue registration status
                case ue_id
                    nil ->
                        IO.puts("No record. Update to register.")
                        Map.put(state.nf_state, ue_id, 1)
                    0 ->
                        IO.puts("Update de-registered to register.")
                        Map.put(state.nf_state, ue_id, 1)
                    1 -> 
                        IO.puts("Already registered.")
                    _ ->
                        IO.puts("No #{ue_id} registration status.")

                    else 
                end
            end        
    
    end

    @spec nf_node(%Server{}, any()) :: no_return()
    def nf_node(state, extra_state) do
        receive do
            # Control message from orchestrator

            # Heartbeat timer, send a heartbeat to the orchestrator
            :timer_heartbeat ->
                send(orchestrator, :heartbeat)
                reset_heartbeat_timer(state)
                nf_node(state, extra_state)
            
            # Nop timer, only received if it is the first nf in the chain and 
            # no messages are received in a while

            # Message from previous hop
            {^prev_hop, {msg, piggyback_logs, commit_vectors}} -> 

            # Messages from clients
            {sender, {msg, piggyback_logs, commit_vectors}} ->
                # update replica
                updated = loop_update_replica(state.replica_storage, piggyback_logs)
                state = %{state | replica_storage: updated_storage}
                # nf process logic and update primary state
                state = nf_process(state, msg)
                piggyback_logs = 
                # TODO: commit_vectors
                # send to the next nf in the chain
                send(next_hop, {msg, piggyback_logs, commit_vectors})


            # Messages for testing

            # Default entry
            _ ->
                nf_node(state, extra_state)
        end
    end

    

end