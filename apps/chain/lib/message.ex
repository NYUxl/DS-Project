defmodule FTC.NewInstance do
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

defmodule FTC.StateResponse do
    @moduledoc """
    When some node fails, orchestrator need to temporaliy pause
    all the nodes, and collect states to reinstall the failed node
    """
    alias __MODULE__
    defstruct(
        id: nil,
        state: nil
    )

    @spec new(atom(), any()) :: %StateResponse{}
    def new(id, replicas) do
        %StateResponse{
            id: id,
            state: replicas
        }
    end
end

defmodule FTC.ChainUpdate do
    @moduledoc """
    The orchestrator use this to tell the node about its new prev_hop
    and next_hop
    """
    alias __MODULE__
    defstruct(
        prev_hop: nil,
        next_hop: nil
    )

    @spec new(atom(), atom()) :: %ChainUpdate{}
    def new(p, n) do
        %ChainUpdate{
            prev_hop: p,
            next_hop: n
        }
    end
end

defmodule FTC.Message do
    @moduledoc """
    Message architecture of the FTC, containing header and content
    """
    alias __MODULE__
    defstruct(
        # header added by gNB
        gnb: nil,
        nonce: nil,
        # content sent by UE
        header: %{ue: nil, pid: nil, src_ip: nil, dst_ip: nil, sub: nil},
        payload: nil # payload 1500 bytes
    )

    # TODO: check the correctness of type
    @spec new(non_neg_integer(), atom(), string(), any(), any(), string()) :: %Message{}
    def new(pid, ue, sb, src, dst, pload) do
        %Message{
            gnb: nil,
            nonce: nil,
            header: %{pid: pid, ue: ue, src_ip: src, dst_ip: dst, sub: sb},
            payload: pload
        }
    end
end

defmodule FTC.MessageResponse do
    @moduledoc """
    Response for a message from the buffer to the gNB
    """
    alias __MODULE__
    defstruct(
        header: %{ue: nil, pid: nil},
        response: nil
    )

    @spec succ(non_neg_integer(), non_neg_integer(), any()) :: %MessageResponse{}
    def succ(ue, pid, additional_message) do
        %MessageResponse{
            header: %{ue: ue, pid: pid},
            response: {:succ, additional_message}
        }
    end

    @spec fail(non_neg_integer(), non_neg_integer()) :: %MessageResponse{}
    def fail(ue, pid) do
        %MessageResponse{
            header: %{ue: ue, pid: pid},
            response: :fail
        }
    end
end

defmodule FTC.StateUpdate do
    @moduledoc """
    The state update message piggybacked to the transmitted message
    """
    alias __MODULE__
    defstruct(
        action: nil,
        key: nil,
        value: nil
    )

    @spec new(string(), any(), non_neg_integer()) :: %StateUpdate{}
    def new(action, key, value) do
        %StateUpdate{
            action: action,
            key: key,
            value: value
        }
    end
end
