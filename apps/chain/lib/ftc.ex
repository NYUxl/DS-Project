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
        nf_to_nodes: nil,
        nodes_to_nf: nil,
        # Timeout for suspection
        live_timeout: nil
    )

    @spec new_configuration(list(atom()), list(atom()), non_neg_integer()) :: %FTC{}
    def new_configuration(view, nf_chain, live_timeout) do
        %FTC{
            view: view,
            nf_chain: nf_chain,
            nf_to_nodes: nil,
            nodes_to_nf: nil,
            live_timeout: live_timeout
        }
    end

    @spec init_state(atom()) :: any()
    def init_state(nf) do
        # TODO: find 
    end

    @spec start(%FTC{}) :: no_return()
    def start(state) do
        node_list = Enum.random(state.view, length(nf_chain))
        state = %{state |
                 nf_to_nodes: Map.new(nf_chain, fn x -> {x, Enum.at(node_list, Enum.find_index(nf_chain, fn nf -> nf == x end))} end),
                 nodes_to_nf: Map.new(node_list, fn x -> {x, Enum.at(nf_chain, Enum.find_index(node_list, fn v -> v == x end))} end)
                }
        
    end

    @spec orchestrator(%FTC{}, any()) :: no_return()
    def orchestrator(state, extra_state) do
    end
end