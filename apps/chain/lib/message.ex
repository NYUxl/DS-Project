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
        rep_group: nil,
        is_first: nil,
        is_last: nil
    )

    @spec new(
        atom(),
        atom(),
        atom(),
        non_neg_integer(),
        list(any()),
        atom(),
        boolean(),
        boolean()
    ) :: 
        %NewInstance{
            nf_name: atom(),
            prev_hop: atom(),
            next_hop: atom(),
            num_of_replications: non_neg_integer(),
            replica_storage: list(any()),
            rep_group: atom(),
            is_first: boolean(),
            is_last: boolean()
        }
    def new(
        nf,
        prev_hop,
        next_hop,
        num_of_replications,
        replica_storage,
        rep_group,
        is_first,
        is_last
    ) do
        %NewInstance{
            nf_name: nf,
            prev_hop: prev_hop,
            next_hop: next_hop,
            num_of_replications: num_of_replications,
            replica_storage: replica_storage,
            rep_group: rep_group,
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

defmodule Server.Message do
    @moduledoc """
    Message architecture of the FTC, containing header and content
    """
    alias __MODULE__
    defstruct(
        nonce: nil,
        header: %{ue: nil, pid: nil, src_ip: nil, dst_ip: nil},
        payload: nil # payload 1500 bytes
    )

    # TODO: check the correctness of type
    @spec new(non_neg_integer(), string(), string(), map(), string()) :: %Message{}
    def new(ue, pid, src, dst, pload) do
        %Message{
            nonce: nil,
            header: %{ue: ue, pid: pid, src_ip: src, dst_ip: dst},
            payload: pload, # ue, loc
        }
    end
    
    @spec update_piggyback(list()) :: %Message{}
    def update_piggyback(packet, new_piggyback) do
        %{packet | piggyback: new_piggyback}
    end

end

defmodule NF.StateUpdate do
    @moduledoc """
    The state update message piggybacked to the transmitted message
    """
    alias __MODULE__
    defstruct(
        action: nil,
        item: nil
    )
end
