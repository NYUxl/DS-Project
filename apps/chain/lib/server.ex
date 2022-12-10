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
    The NF processes the incoming message and update its own state
    """
    @spec nf_update(map(), atom()) :: map()
    
    @doc """
    Update replica's states
    """
    @spec update_replica(list(), list()) :: list(any())
    def update_replica(storage,  update) do
        loop_update_replica(storage, update, 0)
    end

    @doc """
    For loop to update the replica's states
    """
    @spec loop_update_replica(list(), list(), non_neg_integer()) :: list(any())
    def loop_update_replica(storage,  update, idx) do
        if idx < length(storage) do
            case update.action do
                "insert" -> 
                    updated_storage_i = storage.at(idx) 
                    loop_update_replica(storage, update, idx + 1)
                "delete" ->
                    loop_update_replica(storage, update, idx + 1)
                    
                "modify" ->
                    loop_update_replica(storage, update, idx + 1)

                _ ->
                    IO.puts("Not valid operation #{update.action} on storage state update")
        else
            storage
    end

    @spec nf_node(%Server{}, any()) :: no_return()
    def nf_node(state, extra_state) do
        receive do
            # Control message from orchestrator
            
            # Message from previous hop
            {^prev_hop, {logs, commit_vectors, message}} -> 

            # Messages from clients
            {sender, message} ->
                if state is amf


            # Messages for testing

            # Default entry
            _ ->
                nf_node(state, extra_state)
        end
    end

    send(next_hop, {piggyback, message})


    # TODO: re-architecture
    @spec nf_amf_node(%Server{}, any()) :: no_return()
    def nf_amf_node(state, extra_state) do
        receive do
            # Control message from orchestrator
            
            # Messages from clients
            {sender, pkt} ->
                # update replicas
                storage_updates = pkt.piggyback
                update_replica(state.replica_storage, storage_updates)

                # registration procedure
                ud_id = Map.get(pkt.payload, :ue)
                loc = Map.get(pkt.payload, :loc)
                if Map.get(state, ue_id) != True do
                    # send pkt to the next registration procedure step
                    send(:ausf, pkt)
                    nf_amf_node(state, extra_state)
                else # already registered
                    # ack completed to the client
                    send(sender, :ok)
                    nf_amf_node(state, extra_state)

            # Messages for testing

            # Default entry
        end
    end

end