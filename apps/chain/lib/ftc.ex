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
            # TODO: fill in each case

        end
    end

    @doc """
    The start-up step.
    1. Choose some free servers to be each NF
    2. Assign the initial state and replica storages to each NF node
    3. Wait for the NF nodes to send heartbeat to show liveness
    """
    @spec start(%FTC{}) :: no_return()
    def start(state) do
        state = %{state | nodes: Enum.random(state.view, length(nf_chain))}
        
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
        orchestrator(state, Map.new())
    end

    @spec orchestrator(%FTC{}, any()) :: no_return()
    def orchestrator(state, extra_state) do
    end
end