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
        # Basic information
        id: nil,
        orchestrator: nil,
        in_use: nil,
        heartbeat_timeout: nil,
        # Special timeout if this server contains a forwarder
        nop_timeout: nil,
        # State for the own NF
        nf_name: nil,
        nf_state: nil,
        # Information for the NF chain
        prev_hop: nil,
        next_hop: nil,
        num_of_replications: nil,
        replica_storage: nil,
        # Forwarder and Buffer
        is_first: nil,
        is_last: nil,
        forwarder: nil,
        buffer: nil
    )

    @doc """
    Create a new server, and can turn to different nf later
    """
    @spec new_configuration(atom(), non_neg_integer()) :: %Server{}
    def new_configuration(orchestrator, heartbeat_timeout) do
        %Server{
            id: whoami(),
            orchestrator: orchestrator,
            in_use: false,
            heartbeat_timeout: heartbeat_timeout,
            nop_timeout: nil,
            nf_name: nil,
            nf_state: nil,
            prev_hop: nil,
            next_hop: nil,
            num_of_replications: nil,
            replica_storage: nil,
            is_first: nil,
            is_last: nil,
            forwarder: nil,
            buffer: nil
        }
    end

    @doc """
    Called when server initialized or when some failure occurs
    """
    @spec make_server(%Server{}) :: %Server{in_use: false}
    def make_server(state) do
        %{state | in_use: false}
    end

    @spec become_server(%Server{}) :: no_return()
    def become_server(state) do 
        server(make_server(state))
    end

    @spec server(%Server{}) :: no_return()
    def server(state) do
        receive do
            {^state.orchestrator, }
        end
    end
end