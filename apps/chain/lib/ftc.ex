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
                # "AMF state initialized"
                %{} # key:UEid, value:location, registration_state(bool)
            
            :ausf ->
                # "AUSF state initialized"
                %{1 => {"verizon", 0}} # key:UEid, value:{serving_network_name, status}
            
            :smf ->
                # "SMF state initialized"
                %{"verizon" => 100, "mint" => 100, "at&t" => 100} # entries: {key:UEid, value:ip}, extra_entries: {k: sub, v: max_ip} sub: "version", "mint", "at&t"
            
            :upf ->
                # "UPF state initialized"
                %{} # key:src_ip, value:forwarding_port

            _ ->
                IO.puts("Cannot initialize #{nf}")
        end
    end

    @spec reset_live_timer(%FTC{}) :: %FTC{}
    def reset_live_timer(state) do
        if state.live_timer != nil do
            _n = Emulation.cancel_timer(state.live_timer)
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
        state = %{state | nodes: Enum.take_random(state.view, length(state.nf_chain))}
        
        # assign initial states to each node
        initial_states = Enum.map(state.nf_chain, fn x -> init_state(x) end)
        len = length(initial_states)
        # concat over
        double_init = Enum.reverse(initial_states) ++ Enum.reverse(initial_states)
        # send messages to the first and the last node
        send(
            Enum.at(state.nodes, 0),
            FTC.NewInstance.new(
                Enum.at(state.nf_chain, 0),
                Enum.at(state.nodes, len - 1),
                Enum.at(state.nodes, 1),
                state.num_of_replications,
                Enum.slice(double_init, len - 1, state.num_of_replications),
                Enum.at(state.nf_chain, len + 1 - state.num_of_replications),
                true,
                false
            )
        )

        send(
            Enum.at(state.nodes, len - 1),
            FTC.NewInstance.new(
                Enum.at(state.nf_chain, len - 1),
                Enum.at(state.nodes, len - 2),
                Enum.at(state.nodes, 0),
                state.num_of_replications,
                Enum.slice(double_init, 0, state.num_of_replications),
                Enum.at(state.nf_chain, len - state.num_of_replications),
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
                    FTC.NewInstance.new(
                        Enum.at(state.nf_chain, idx),
                        Enum.at(state.nodes, idx - 1),
                        Enum.at(state.nodes, idx + 1),
                        state.num_of_replications,
                        Enum.slice(double_init, len - 1 - idx, state.num_of_replications),
                        Enum.at(state.nf_chain, rem(len + idx + 1 - state.num_of_replications, len)),
                        false,
                        false
                    )
                ) 
            end
        )

        # wait for heartbeat
        state = reset_live_timer(state)
        orchestrator(state, reset_extra_state(state))
    end

    @spec alive_or_prev(list(atom()), list(atom()), non_neg_integer()) :: non_neg_integer()
    def alive_or_prev(chain, deads, idx) do
        if Enum.find(deads, fn v -> v == Enum.at(chain, idx) end) do
            alive_or_prev(chain, deads, rem(idx + length(chain) - 1, length(chain)))
        else
            idx
        end
    end

    @spec alive_or_next(list(atom()), list(atom()), non_neg_integer()) :: non_neg_integer()
    def alive_or_next(chain, deads, idx) do
        if Enum.find(deads, fn v -> v == Enum.at(chain, idx) end) do
            alive_or_next(chain, deads, rem(idx + 1, length(chain)))
        else
            idx
        end
    end

    @spec wait_for_state_response(atom()) :: any()
    def wait_for_state_response(node) do
        receive do
            {^node, %FTC.StateResponse{id: ^node, state: replica}} ->
                replica
            
            _ ->
                wait_for_state_response(node)
        end
    end

    @doc """
    To make sure both p_node and n_node are all valid keys in the storages
    """
    @spec update_storages(map(), atom(), atom()) :: map()
    def update_storages(storages, p_node, n_node) do
        if Map.get(storages, p_node) == nil do
            send(p_node, :get_state)
            replica = wait_for_state_response(p_node)
            storages = Map.put(storages, p_node, replica)

            if Map.get(storages, n_node) == nil do
                send(n_node, :get_state)
                replica = wait_for_state_response(n_node)
                storages = Map.put(storages, n_node, replica)
                storages
            else
                storages
            end
        else
            if Map.get(storages, n_node) == nil do
                send(n_node, :get_state)
                replica = wait_for_state_response(n_node)
                storages = Map.put(storages, n_node, replica)
                storages
            else
                storages
            end
        end
    end

    @spec fix_node_at(%FTC{}, list(atom()), list(atom()), map(), non_neg_integer()) :: %FTC{}
    def fix_node_at(state, dead_nodes, new_nodes, storages, idx) do
        IO.puts("fix node at #{idx} in the dead node list")
        if idx < length(dead_nodes) do
            # nodes before idx are fixed, now to fix idx-th node
            # retrieve the state and restore the node
            chain_idx = Enum.find_index(state.nodes, fn x -> x == Enum.at(dead_nodes, idx) end)
            len = length(state.nodes)
            prev_idx = alive_or_prev(state.nodes, dead_nodes, rem(chain_idx + len - 1, len))
            prev_node = Enum.at(state.nodes, prev_idx)
            next_idx = alive_or_next(state.nodes, dead_nodes, rem(chain_idx + 1, len))
            next_node = Enum.at(state.nodes, next_idx)
            # pull some state if needed
            storages = update_storages(storages, prev_node, next_node)
            # reconstruct the replica state
            reconstructed_replica_1 = Enum.drop(Map.get(storages, next_node), rem(next_idx + len - chain_idx, len))
            reconstructed_replica_2 = Enum.take(Map.get(storages, prev_node), rem(chain_idx + len - prev_idx, len))
            reconstructed_replica = reconstructed_replica_1 ++ reconstructed_replica_2

            send(
                Enum.at(new_nodes, chain_idx),
                FTC.NewInstance.new(
                    Enum.at(state.nf_chain, chain_idx),
                    Enum.at(new_nodes, rem(chain_idx + len - 1, len)),
                    Enum.at(new_nodes, rem(chain_idx + 1, len)),
                    state.num_of_replications,
                    reconstructed_replica,
                    Enum.at(state.nf_chain, len - state.num_of_replications),
                    if(chain_idx == 0, do: true, else: false),
                    if(chain_idx == (length(state.nodes) - 1), do: false, else: true)
                )
            )

            # to next iter
            fix_node_at(state, dead_nodes, new_nodes, storages, idx + 1)
        else
            # all dead nodes fixed
            %{state | nodes: new_nodes}
        end
    end

    @spec fix_nodes(%FTC{}, list(atom())) :: %FTC{}
    def fix_nodes(state, dead_nodes) do
        # it would be better if we can make sure that there are enough alive servers
        # other than the dead ones, but it is ok to assume that they are still usable
        avail_nodes = state.view -- state.nodes ++ dead_nodes
        selected_nodes = Enum.take_random(avail_nodes, length(dead_nodes))
        new_nodes = Enum.reduce(
            Range.new(0, length(dead_nodes) - 1), 
            state.nodes, 
            fn x, acc -> List.replace_at(
                acc, 
                Enum.find_index(acc, fn n -> n == Enum.at(dead_nodes, x) end), 
                Enum.at(selected_nodes, x)
            ) end
        )
        state = fix_node_at(state, dead_nodes, new_nodes, %{}, 0)
        state
    end 

    @spec orchestrator(%FTC{}, any()) :: no_return()
    def orchestrator(state, extra_state) do
        receive do
            # heartbeat message from a node
            {sender, :heartbeat} -> 
                # IO.puts("#{whoami()}(orchestrator): heartbeat received from #{sender}")
                extra_state = Map.put(extra_state, sender, 1)
                if Enum.any?(Map.values(extra_state), fn x -> x == 0 end) do
                    orchestrator(state, extra_state)
                else
                    # IO.puts("Reset liveness timer")
                    state = reset_live_timer(state)
                    orchestrator(state, reset_extra_state(state))
                end
            
            # liveness timer received, some node died
            # 1. stop the process
            # 2. recreate an instance and restore the state
            # 3. continue the process
            :timer ->
                IO.puts("#{whoami()}(orchestrator): timer received, some node died")
                dead_nodes = Enum.filter(state.nodes, fn x -> Map.get(extra_state, x) == 0 end)
                IO.puts("Dead nodes list length: #{length(dead_nodes)}")
                alive_nodes = Enum.filter(state.nodes, fn x -> Map.get(extra_state, x) == 1 end)
                # to make sure the node is terminated
                Enum.map(dead_nodes, fn x -> send(x, :terminate) end)
                # to stop the whole process
                Enum.map(alive_nodes, fn x -> send(x, :pause) end)

                state = fix_nodes(state, dead_nodes)
                # to resume the whole process
                len = length(state.nodes)
                Enum.map(alive_nodes, fn x -> 
                    chain_idx = Enum.find_index(state.nodes, fn n -> n == x end)
                    send(
                        x,
                        FTC.ChainUpdate.new(
                            Enum.at(state.nodes, rem(chain_idx + len - 1, len)),
                            Enum.at(state.nodes, rem(chain_idx + 1, len))
                        )
                    )
                end)
                Enum.map(alive_nodes, fn x -> send(x, :resume) end)
                state = reset_live_timer(state)
                orchestrator(state, reset_extra_state(state))
            
            # the chain head query from the gNB
            {sender, :request_for_head} ->
                send(sender, {:current_head, hd(state.nodes)})
                orchestrator(state, extra_state)
            
            # for testing
            {sender, :master_get_nodes} ->
                send(sender, state.nodes)
                orchestrator(state, extra_state)
        end
    end
end

defmodule FTC.GNB do
    @moduledoc """
    gNB for 5G infrastructure. Forward the message to the forwarder to enter
    the chain
    """
    alias __MODULE__

    import Emulation, only: [send: 2, timer: 1, timer: 2, now: 0, whoami: 0]

    import Kernel,
        except: [spawn: 3, spawn: 1, spawn_link: 1, spawn_link: 3, send: 2]

    defstruct(
        id: nil,
        orchestrator: nil,
        wait_timeout: nil,
        wait_timer: nil,
        # the latest nonce to tag
        nonce: nil,
        # the next nonce to send, should be <= nonce
        nonce_to_send: nil,
        # if some message got no response for long time, we should return fail
        expire_thres: nil,
        buffer: nil,
        current_head: nil
    )

    @retry_timeout 1000

    @spec new_gNB(atom(), non_neg_integer()) :: %GNB{}
    def new_gNB(orchestrator, thres) do
        %GNB{
            id: whoami(),
            orchestrator: orchestrator,
            wait_timeout: @retry_timeout,
            wait_timer: nil,
            nonce: 1,
            nonce_to_send: 1,
            expire_thres: thres,
            buffer: {},
            current_head: nil
        }
    end

    @spec send_messages(%GNB{}) :: %GNB{}
    def send_messages(state) do
        if state.nonce_to_send < state.nonce do
            send(state.current_head, Map.get(state.buffer, state.nonce_to_send))
            state = %{state | nonce_to_send: state.nonce_to_send + 1}
            send_messages(state)
        else
            state
        end
    end

    @spec startup(%GNB{}) :: no_return()
    def startup(state) do
        state = %{state | wait_timer: Emulation.timer(state.wait_timeout)}
        send(state.orchestrator, :request_for_head)
        state = %{state | current_head: :waiting}
        gNB(state)
    end

    @spec gNB(%GNB{}) :: no_return()
    def gNB(state) do
        orch = state.orchestrator
        receive do
            # message from orchestrator for current chain head
            {^orch, {:current_head, dealer}} ->
                Emulation.cancel_timer(state.wait_timer)
                state = %{state | wait_timer: nil, current_head: dealer}
                state = send_messages(state)
                gNB(state)

            # need to ask for the chain entry
            {_node, {:not_entry, nonce}} ->
                state = %{state | wait_timer: Emulation.timer(state.wait_timeout)}
                send(orch, :request_for_head)
                state = %{state | current_head: :waiting, nonce_to_send: nonce}
                gNB(state)
            
            :timer ->
                state = %{state | wait_timer: Emulation.timer(state.wait_timeout)}
                send(orch, :request_for_head)
                gNB(state)

            # response from buffer
            {_node, {:done, nonce, updated_header}} ->
                # do nothing if the corresponding message is dropped earlier
                if not Map.has_key?(state.buffer, nonce) do
                    gNB(state)
                end

                # retrieve the message
                {req_sender, message} = Map.get(state.buffer, nonce)
                send(req_sender, FTC.MessageResponse.succ(message.header.ue, message.header.pid, updated_header))

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
                message = %{message | gnb: state.id, nonce: state.nonce}
                state = %{state | buffer: Map.put(state.buffer, state.nonce, {sender, message})}
                # update the nonce
                state = %{state | nonce: state.nonce + 1}
                
                # for the first message, ask the orchestrator about the chain entry
                case state.current_head do
                    nil ->
                        send(orch, :request_for_head)
                        state = %{state | current_head: :waiting}
                        gNB(state)
                    
                    :waiting ->
                        gNB(state)
                
                    _node ->
                        send_messages(state)
                        state = %{state | nonce_to_send: state.nonce_to_send + 1}
                        gNB(state)
                end
        end
    end
end

defmodule FTC.UE do
    @moduledoc """
    User equipment. Send message to the assigned gNB
    """
    alias __MODULE__

    import Emulation, only: [send: 2, timer: 1, timer: 2, now: 0, whoami: 0]

    import Kernel,
        except: [spawn: 3, spawn: 1, spawn_link: 1, spawn_link: 3, send: 2]

    defstruct(
        id: nil,
        gnb: nil,
        # subscriber
        sub: nil,
        # ip address
        ip: nil
    )

    @spec new_ue(atom(), atom(), string()) :: %UE{}
    def new_ue(id, gnb, sub) do
        %UE{
            id: id,
            gnb: gnb,
            sub: sub,
            ip: nil
        }
    end
end
