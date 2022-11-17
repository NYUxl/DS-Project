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
        
    )
end