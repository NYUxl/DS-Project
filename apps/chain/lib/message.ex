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
        replica_storage: nil,
        commit_vector: nil,
        is_first: nil,
        is_last: nil
    )

    @spec new(
        atom(),
        atom(),
        atom(),
        non_neg_integer(),
        list(any()),
        non_neg_integer(),
        boolean(),
        boolean()
    ) :: 
        %NewInstance{
            nf_name: atom(),
            prev_hop: atom(),
            next_hop: atom(),
            num_of_replications: non_neg_integer(),
            replica_storage: list(any()),
            commit_vector: non_neg_integer(),
            is_first: boolean(),
            is_last: boolean()
        }
    def new(
        nf,
        prev_hop,
        next_hop,
        num_of_replications,
        replica_storage,
        commit_vector,
        is_first,
        is_last
    ) do
        %NewInstance{
            nf_name: nf,
            prev_hop: prev_hop,
            next_hop: next_hop,
            num_of_replications: num_of_replications,
            replica_storage: replica_storage,
            commit_vector: commit_vector,
            is_first: is_first,
            is_last: is_last
        }
    end
end

defmodule Server.StateResponse do
    @moduledoc """
    When some node fails, orchestrator need to temporaliy pause
    all the nodes
    """
    alias __MODULE__
    defstruct(
        id: nil,
        state: nil
    )

    @spec new(any()) :: %StateResponse{}
    def new(id, nf_state) do
        %StateResponse{
            id: id,
            state: nf_state
        }
    end
end

defmodule SomeName do
    @moduledoc """
    
    """
    alias __MODULE__
    defstruct(
        default: nil
    )
end

defmodule SomeName do
    @moduledoc """
    
    """
    alias __MODULE__
    defstruct(
        default: nil
    )
end

defmodule FTC.Packet do
    @moduledoc """
    Packet architecture of the FTC, containing header and content
    """
    alias __MODULE__
    defstruct(
        header: %{ue: nil, pid: nil, src_ip: nil, dst_ip: nil}
        payload: "payload 1500 bytes"
        piggyback: nil
    )

    # TODO: check the correctness of type
    @spec new(non_neg_integer(), string(), string(), map(), list()) :: %Packet{}
    def new(p_id, hd, pload, pback) do
        %Packet{
            header: hd, # %{pid: p_id, src_ip: src, dst_ip: dst}
            payload: pload, # ue, loc
            piggyback: pback
        }
    end
    
    @spec update_piggyback(list()) :: %Packet{}
    def update_piggyback(packet, new_piggyback) do
        %{packet | piggyback: new_piggyback}
    end

end