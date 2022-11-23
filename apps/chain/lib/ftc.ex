defmodule FTC do
    @moduledoc """
    The orchestrator. It should be fault-tolerant itself. Just
    assume that it will not fail
    """

    # Shouldn't need to spawn anything from this module
    import Emulation, only: [send: 2, timer: 1, timer: 2, now: 0, whoami: 0]

    import Kernel,
        except: [spawn: 3, spawn: 1, spawn_link: 1, spawn_link: 3, send: 2]

    require Fuzzers

    # General structure of an orchestrator
    defstruct(
        # All the available servers
        view: nil,
        # The required NF chain and assigned server
        nf_chain: nil,
        nodes: nil,
        num_of_replications: nil,
        # Timeout for suspection
        live_timeout: nil,
        live_timer: nil,
        heartbeat_counter: nil
    )

    @spec new_configuration(list(atom()), list(atom()), non_neg_integer(), non_neg_integer()) :: %FTC{}
    def new_configuration(view, nf_chain, num_of_replications, live_timeout) do
        %FTC{
            view: view,
            nf_chain: nf_chain,
            nodes: nil,
            num_of_replications: num_of_replications,
            live_timeout: live_timeout,
            live_timer: nil,
            heartbeat_counter: nil
        }
    end

    @doc """
    Get the initial state for each NF, used at start-up
    """
    @spec init_state(atom()) :: any()
    def init_state(nf) do
        case nf do
            :amf ->
                "AMF state initialized"
                %{} # key:UEid, value:location, registration_state(bool)
            :ausf ->
                "AUSF state initialized"
                %{1: {"Verizon", 0}} # key:UEid, value:{serving_network_name, status}
            :smf ->
                "SMF state initialized"
                %{} # key:UEid, value:ip
            :upf ->
                "UPF state initialized"
                %{} # key:src_ip, value:forwarding_port
            _ ->
                "Cannot initialize #{nf}"
        end
    end

    @spec reset_live_timer(%FTC{}) :: %FTC{}
    def reset_live_timer(state) do
        if state.live_timer != nil do
            n = Emulation.cancel_timer(state.live_timer)
        end
        %{state | live_timer: Emulation.timer(state.live_timeout)}
    end

    @spec reset_extra_state(%FTC{}) :: any()
    def reset_extra_state(state) do
        Map.new(state.nodes, fn x -> {x, 0} end)
    end

    @doc """
    The start-up step
    1. choose some free servers to be each NF
    2. assign the initial state and replica storages to each NF node
    3. wait for the NF nodes to send heartbeat to show liveness
    """
    @spec start(%FTC{}) :: no_return()
    def start(state) do
        state = %{state | nodes: Enum.take_random(state.view, length(nf_chain))}
        
        # assign initial states to each node
        initial_states = Enum.map(state.nf_chain, fn x -> init_state(x) end)
        len = length(initial_states)
        # concat over
        double_init = Enum.reverse(initial_states) ++ Enum.reverse(initial_states)
        # send messages to the first and the last node
        send(
            Enum.at(state.nodes, 0),
            Server.NewInstance.new(
                Enum.at(state.nf_chain, 0),
                nil,
                Enum.at(state.nodes, 1),
                state.num_of_replications,
                Enum.slice(double_init, len - 1, state.num_of_replications),
                0,
                true,
                false
            )
        )

        send(
            Enum.at(state.nodes, len - 1),
            Server.NewInstance.new(
                Enum.at(state.nf_chain, len - 1),
                Enum.at(state.nodes, len - 2),
                nil,
                state.num_of_replications,
                Enum.slice(double_init, 0, state.num_of_replications),
                0,
                false,
                true
            )
        )
        # send messages to all the other nodes
        _ = Enum.map(
            Range.new(1, len - 2),
            fn idx -> 
                send(
                    Enum.at(state.nodes, idx),
                    Server.NewInstance.new(
                        Enum.at(state.nf_chain, idx),
                        Enum.at(state.nodes, idx - 1),
                        Enum.at(state.nodes, idx + 1),
                        state.num_of_replications,
                        Enum.slice(double_init, len - 1 - idx, state.num_of_replications),
                        0,
                        false,
                        false
                    )
                ) 
            end
        )

        # wait for heartbeat
        state = reset_live_timer(state)
        orchestrator(state, reset_extra_state())
    end

    @spec fix_node_at(%FTC{}, list(atom()), map(), non_neg_integer()) :: %FTC{}
    def fix_node_at(state, dead_nodes, storages, idx) do
        if idx < length(dead_nodes) do
            # nodes before idx are fixed, now to fix idx-th node
            avail_list = Enum.filter(state.view, fn x -> )
            new_node = Enum.random()
        else
            # all dead nodes fixed
            state
        end
    end

    @spec fix_nodes(%FTC{}, list(atom())) :: %FTC{}
    def fix_nodes(state, dead_nodes) do
        alive_nodes = state.view -- state.nodes ++ dead_nodes
        fix_node_at(state, dead_nodes, %{}, 0)
    end 

    @spec orchestrator(%FTC{}, any()) :: no_return()
    def orchestrator(state, extra_state) do
        receive do
            # heartbeat message from a node
            {sender, {:heartbeat}} -> 
                extra_state = Map.put(extra_state, sender, 1)
                if Enum.any?(Map.values(extra_state), fn x -> x == 0 end) do
                    orchestrator(state, extra_state)
                else
                    state = reset_live_timer(state)
                    orchestrator(state, reset_extra_state())
                end
            
            # liveness timer received, some node died
            # 1. stop the process
            # 2. recreate an instance and restore the state
            # 3. continue the process
            :timer ->
                dead_nodes = Enum.filter(state.nodes, fn x -> Map.get(extra_state, x) == 0 end)
                alive_nodes = Enum.filter(state.nodes, fn x -> Map.get(extra_state, x) == 1 end)
                # to make sure the node is terminated
                Enum.map(dead_nodes, fn x -> send(x, :terminate) end)
                # to stop the whole process
                Enum.map(alive_nodes, fn x -> send(x, :pause) end)

                state = fix_nodes(state, dead_nodes)
                # to resume the whole process
                Enum.map(alive_nodes, fn x -> send(x, :resume) end)
        end
    end
end

defmodule GNB do
    @moduledoc """
    gNB for 5G infrastructure. Forward the message to the forwarder to enter
    the chain
    """
    defstruct(
        id: nil,
        orchestrator: nil,
        # the latest nonce to tag
        nonce: nil,
        # the next nonce to send, should be <= nonce
        nonce_to_send: nil,
        # if some message got no response for long time, we should return fail
        expire_thres: nil,
        buffer: nil,
        current_dealer: nil
    )

    @spec new_gNB(atom(), atom(), non_neg_integer()) :: %GNB{}
    def new_gNB(id, orchestrator, thres) do
        %GNB{
            id: id,
            orchestrator: orchestrator,
            nonce: 0,
            nonce_to_send: 0,
            expire_thres: thres,
            buffer: {},
            current_head: nil
        }
    end

    @spec send_messages(%GNB{}) :: %GNB()
    def send_messages(state) do
        if state.nonce_to_send < state.nonce do
            send(state.current_head, Map.get(state.buffer, state.nonce_to_send))
            state = %{state | nonce_to_send: state.nonce_to_send + 1}
            send_messages(state)
        else
            state
        end
    end

    @spec gNB(%GNB{}) :: no_return()
    def gNB(state) do
        receive do
            # message from orchestrator for current chain head
            {^state.orchestrator, {:current_head, dealer}} ->
                state = %{state | current_head: dealer}
                state = send_messages(state)
                gNB(state)

            # need to ask for the chain entry
            {node, {:not_entry, nonce}} ->
                send(state.orchestrator, :request_for_head)
                state = %{state | current_head: :waiting, nonce_to_send: nonce}
                gNB(state)
            
            # response from buffer
            {node, {:done, nonce}} ->
                # do nothing if the corresponding message is dropped earlier
                if not Map.has_key?(state.buffer, nonce) do
                    gNB(state)
                end

                # retrieve the message
                {req_sender, message} = Map.get(state.buffer, nonce)
                send(req_sender, Server.MessageResponse.succ(message.header.ue, message.header.pid))

                state = %{state | buffer: Map.pop(state.buffer, nonce)}
                nonces = Enum.filter(Map.keys(state.buffer), fn x -> x < state.nonce - state.expire_thres end)
                if Enum.empty?(nonces) do
                    gNB(state)
                else
                    # retry outdated messages (here we assume that messages are retriable)
                    new_messages = Enum.map(Range.new(0, length(nonces) - 1), fn x ->
                        {req_sender, message} = Map.get(state.buffer, Enum.at(nonces, x))
                        message = %{message | nonce: state.nonce + x}
                        {state.nonce + x, {req_sender, message}}
                    end)
                    state = %{state | buffer: Map.merge(state.buffer, Map.new(new_messages))}
                    state = %{state | nonce: state.nonce + length(nonces)}
                    send_messages(state)

                    state = %{state | buffer: Map.drop(state.buffer, nonces)}
                    gNB(state)
                end

            # new request from UE
            {sender, message} ->
                # tag the message with the current nonce
                message = %{message | nonce: state.nonce}
                state = %{state | buffer: Map.put(state.buffer, state.nonce, {sender, message})}
                # update the nonce
                state = %{state | nonce: state.nonce + 1}
                
                # for the first message, ask the orchestrator about the chain entry
                case state.current_head do
                    nil ->
                        send(state.orchestrator, :request_for_head)
                        state = %{state | current_head: :waiting}
                        gNB(state)
                    
                    :waiting ->
                        gNB(state)
                
                    node ->
                        send_messages(state)
                        state = %{state | nonce_to_send: state.nonce_to_send + 1}
                        gNB(state)
                end
        end
    end

defmodule UE do
    @moduledoc """
    User equipment. Send message to the assigned gNB
    """
    defstruct(
        id: nil,
        gnb: nil
    )

    @spec new_client(atom(), atom()) :: %UE{}
    def new_client(id, gnb) do
        %UE{
            id: id,
            gnb: gnb
        }
    end
end
