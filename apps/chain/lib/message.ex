defmodule Server.NewInstance do
    @moduledoc """
    Used when the orchestrator wants to turn a server into some NF
    """
    alias __MODULE__
    defstruct(
        nf_name: nil,
        prev_hop: nil,
        next_hop: nil,
        num_of_replications: nil,
        is_first: nil,
        is_last: nil
    )

    @spec new() :: %NewInstance{}
end

defmodule FTC.Packet do
    @moduledoc """
    Packet architecture of the FTC, containing header and content
    """
    alias __MODULE__
    defstruct(

    )
end