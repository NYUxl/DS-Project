defmodule FTCTest do
    use ExUnit.Case
    doctest FTC

    import Kernel,
        except: [spawn: 3, spawn: 1, spawn_link: 1, spawn_link: 3, send: 2]

    import Emulation, only: [spawn: 2, send: 2, whoami: 0]

    @spec spawn_server(atom()) :: no_return()
    def spawn_server(node) do
        spawn(node, fn -> 
            FTC.Server.become_server(
                FTC.Server.new_configuration(
                    node,
                    :orch,
                    1000,
                    200
                )
            )
        end)
    end

    test "Nothing crashes during startup and heartbeats" do
        Emulation.init()
        Emulation.append_fuzzers([Fuzzers.delay(2)])

        base_config = FTC.new_configuration(
            [:a, :b, :c, :d, :e],
            [:amf, :ausf, :smf, :upf],
            3,
            3000
        )

        spawn_server(:a)
        spawn_server(:b)
        spawn_server(:c)
        spawn_server(:d)
        spawn_server(:e)

        spawn(:orch, fn -> FTC.start(base_config) end)
        spawn(:gnb, fn -> FTC.GNB.startup(FTC.GNB.new_gNB(:orch, 20)) end)

        client = spawn(:client, fn ->
            u1 = FTC.UE.new_ue(:u1, :gnb)

            receive do
            after
            10000 -> true
            end
        end)

        handle = Process.monitor(client)
        # Timeout.
        receive do
            {:DOWN, ^handle, _, _, _} -> true
        after
        30000 -> assert false
        end
    after
        Emulation.terminate()
    end

    @spec get_assigned(atom()) :: list(atom())
    def get_assigned(orch) do
        send(orch, :master_get_nodes)
        receive do
            {^orch, assigned} ->
                assigned
            
            _ ->
                []
        end
    end

    @spec get_from_node(atom(), atom()) :: any()
    def get_from_node(node, key) do
        send(node, {:master_get, key})
        receive do
            {^node, ret} ->
                ret
            
            _ ->
                nil
        end
    end

    test "Consistency when start-up" do
        Emulation.init()
        Emulation.append_fuzzers([Fuzzers.delay(2)])
        
        view = [:a, :b, :c, :d, :e]
        chain = [:amf, :ausf, :smf, :upf]

        base_config = FTC.new_configuration(
            view,
            chain,
            3,
            3000
        )

        spawn_server(:a)
        spawn_server(:b)
        spawn_server(:c)
        spawn_server(:d)
        spawn_server(:e)

        spawn(:orch, fn -> FTC.start(base_config) end)
        spawn(:gnb, fn -> FTC.GNB.startup(FTC.GNB.new_gNB(:orch, 20)) end)

        master = spawn(:master, fn ->
            u1 = FTC.UE.new_ue(:u1, :gnb)

            receive do
            after
            1_000 -> true
            end
            
            assigned = get_assigned(:orch)
            assert (assigned != [])

            in_use = Map.new(Enum.map(view, fn x ->
                {x, get_from_node(x, :in_use)}
            end))
            cnt_false = Enum.count(Map.values(in_use), fn x -> x == false end)
            assert (cnt_false == 1)
            cnt_false = Enum.count(Map.values(Map.take(in_use, assigned)), fn x -> x == false end)
            assert (cnt_false == 0)

            receive do
            after
            1_000 -> :ok
            end

            functions = Enum.map(view, fn x ->
                {x, get_from_node(x, :nf_name)}
            end)
            gt = Enum.map(Range.new(0, length(chain) - 1), fn x ->
                {Enum.at(assigned, x), Enum.at(chain, x)}
            end)
            assert (Map.equal?(Map.take(Map.new(functions), assigned), Map.new(gt)))
        end)

        handle = Process.monitor(master)
        # Timeout.
        receive do
            {:DOWN, ^handle, _, _, _} -> true
        after
        30_000 -> assert false
        end
    after
        Emulation.terminate()
    end

    @spec spawn_ue(atom(), atom(), string()) :: no_return()
    def spawn_ue(a, gnb, sub) do
        spawn(a, fn ->
            FTC.UE.ue(
                FTC.UE.new_ue(
                    a,
                    gnb,
                    sub
                )
            )
        end)
    end

    @spec spawn_ues(list(atom()), atom(), list(string())) :: no_return()
    def spawn_ues(ues, gnb, subs) do
    end

    test "NF functions correctly" do
        Emulation.init()
        Emulation.append_fuzzers([Fuzzers.delay(2)])
        
        view = [:a, :b, :c, :d, :e]
        chain = [:amf, :ausf, :smf, :upf]

        base_config = FTC.new_configuration(
            view,
            chain,
            3,
            3000
        )

        spawn_server(:a)
        spawn_server(:b)
        spawn_server(:c)
        spawn_server(:d)
        spawn_server(:e)

        spawn(:orch, fn -> FTC.start(base_config) end)
        spawn(:gnb, fn -> FTC.GNB.startup(FTC.GNB.new_gNB(:orch, 20)) end)

        master = spawn(:master, fn ->
            u1 = FTC.UE.new_ue(:u1, :gnb)

            receive do
            after
            1_000 -> true
            end

            in_use = Map.new(Enum.map(view, fn x ->
                {x, get_from_node(x, :in_use)}
            end))
            cnt_false = Enum.count(Map.values(in_use), fn x -> x == false end)
            assert (cnt_false == 1)

            assigned = get_assigned(:orch)
            send(Enum.at(assigned, 0), :master_terminate)

            receive do
            after
            10_000 -> true
            end

            in_use = Map.new(Enum.map(view, fn x ->
                {x, get_from_node(x, :in_use)}
            end))
            cnt_false = Enum.count(Map.values(in_use), fn x -> x == false end)
            assert (cnt_false == 1)
        end)

        handle = Process.monitor(client)
        # Timeout.
        receive do
            {:DOWN, ^handle, _, _, _} -> true
        after
        30_000 -> assert false
        end
    after
        Emulation.terminate()
    end
    
    test "Recovery works without traffic" do
        Emulation.init()
        Emulation.append_fuzzers([Fuzzers.delay(2)])
        
        view = [:a, :b, :c, :d, :e]
        chain = [:amf, :ausf, :smf, :upf]

        base_config = FTC.new_configuration(
            view,
            chain,
            3,
            3000
        )

        spawn_server(:a)
        spawn_server(:b)
        spawn_server(:c)
        spawn_server(:d)
        spawn_server(:e)

        spawn(:orch, fn -> FTC.start(base_config) end)
        spawn(:gnb, fn -> FTC.GNB.startup(FTC.GNB.new_gNB(:orch, 20)) end)

        master = spawn(:master, fn ->
            u1 = FTC.UE.new_ue(:u1, :gnb)

            receive do
            after
            1_000 -> true
            end

            in_use = Map.new(Enum.map(view, fn x ->
                {x, get_from_node(x, :in_use)}
            end))
            cnt_false = Enum.count(Map.values(in_use), fn x -> x == false end)
            assert (cnt_false == 1)

            assigned = get_assigned(:orch)
            send(Enum.at(assigned, 0), :master_terminate)

            receive do
            after
            10_000 -> true
            end

            in_use = Map.new(Enum.map(view, fn x ->
                {x, get_from_node(x, :in_use)}
            end))
            cnt_false = Enum.count(Map.values(in_use), fn x -> x == false end)
            assert (cnt_false == 1)
        end)

        handle = Process.monitor(master)
        # Timeout.
        receive do
            {:DOWN, ^handle, _, _, _} -> true
        after
        30_000 -> assert false
        end
    after
        Emulation.terminate()
    end
end