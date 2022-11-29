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
        if not Enum.empty?(ues) do
            spawn_ue(hd(ues), gnb, hd(subs))
            spawn_ues(tl(ues), gnb, tl(subs))
        end
    end

    test "Nothing crashes during startup and heartbeats" do
        # IO.puts("Nothing crashes during startup and heartbeats")
        Emulation.init()
        Emulation.append_fuzzers([Fuzzers.delay(2)])
        
        view = [:a, :b, :c, :d, :e]
        chain = [:amf, :ausf, :smf, :upf]
        ues = [:u1]
        subs = ["verizon"]

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
        spawn(:gnb, fn -> FTC.GNB.startup(FTC.GNB.new_gNB(:orch)) end)

        spawn_ues(ues, :gnb, subs)

        master = spawn(:master, fn ->
            receive do
            after
            10000 -> true
            end
        end)

        handle = Process.monitor(master)
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
        # IO.puts("Consistency when start-up")
        Emulation.init()
        Emulation.append_fuzzers([Fuzzers.delay(2)])
        
        view = [:a, :b, :c, :d, :e]
        chain = [:amf, :ausf, :smf, :upf]
        ues = [:u1]
        subs = ["verizon"]

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
        spawn(:gnb, fn -> FTC.GNB.startup(FTC.GNB.new_gNB(:orch)) end)

        spawn_ues(ues, :gnb, subs)

        master = spawn(:master, fn ->
            # Some time to settle down
            receive do
            after
            1_000 -> true
            end
            
            # Nodes in use are active
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

            # Each server gets the correct NF
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
    

    test "Recovery works without traffic" do
        # IO.puts("Recovery works without traffic")
        Emulation.init()
        Emulation.append_fuzzers([Fuzzers.delay(2)])
        
        view = [:a, :b, :c, :d, :e]
        chain = [:amf, :ausf, :smf, :upf]
        ues = [:u1]
        subs = ["verizon"]

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
        spawn(:gnb, fn -> FTC.GNB.startup(FTC.GNB.new_gNB(:orch)) end)

        spawn_ues(ues, :gnb, subs)

        master = spawn(:master, fn ->
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
            send(Enum.at(Enum.take_random(assigned, 1), 0), :master_terminate)

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

    test "NF logic functions correctly without failure" do
        # IO.puts("NF logic functions correctly without failure")
        Emulation.init()
        Emulation.append_fuzzers([Fuzzers.delay(2)])
        
        view = [:a, :b, :c, :d, :e]
        chain = [:amf, :ausf, :smf, :upf]
        ues = [:u1, :u2]
        subs = ["verizon", "veri"]

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
        spawn(:gnb, fn -> FTC.GNB.startup(FTC.GNB.new_gNB(:orch)) end)
        
        spawn_ues(ues, :gnb, subs)

        master = spawn(:master, fn ->
            Enum.map(ues, fn x -> send(x, :master_send_req) end)

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

            receive do
            after
            10_000 -> true
            end
            
            in_use = Map.new(Enum.map(view, fn x ->
                {x, get_from_node(x, :in_use)}
            end))
            cnt_false = Enum.count(Map.values(in_use), fn x -> x == false end)
            assert (cnt_false == 1)
            
            # nf has right state information
            assert(get_from_node(Enum.at(assigned, 0), :nf_state) == %{u1: 1, u2: 1})
            assert(get_from_node(Enum.at(assigned, 1), :nf_state) == %{u1: {"verizon", 1}})
            assert(get_from_node(Enum.at(assigned, 2), :nf_state) == %{"verizon" => 101, "at&t" => 100, "mint" => 100, :u1 => "168.168.168.101"})
            assert(get_from_node(Enum.at(assigned, 3), :nf_state) == %{"168.168.168.101" => 1})


            # u1 will get ip and u2 will not get ip
            ips = Enum.map(ues, fn x ->
                {x, (get_from_node(x, :ip) == nil)}
            end)
            gt = %{u1: false, u2: true}
            assert (Map.equal?(Map.new(ips), gt))
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

    test "NF functions correctly with failures" do
        # IO.puts("NF functions correctly with failures")
        Emulation.init()
        Emulation.append_fuzzers([Fuzzers.delay(2)])
        
        view = [:a, :b, :c, :d, :e]
        chain = [:amf, :ausf, :smf, :upf]
        ues1 = [:u1, :u2]
        subs1 = ["verizon", "veri"]
        ues2 = [:u3, :u4, :u5, :u6]
        subs2 = ["verizon", "mint", "at&t", "at"]

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
        spawn(:gnb, fn -> FTC.GNB.startup(FTC.GNB.new_gNB(:orch)) end)
        
        spawn_ues(ues1, :gnb, subs1)
        spawn_ues(ues2, :gnb, subs2)

        master = spawn(:master, fn ->
            receive do
            after
            1_000 -> true
            end

            # group 1 send requests
            Enum.map(ues1, fn x -> send(x, :master_send_req) end)

            receive do
            after
            1_000 -> true
            end

            ips = Enum.map(ues1, fn x ->
                {x, (get_from_node(x, :ip) == nil)}
            end)
            gt = %{u1: false, u2: true}
            assert (Map.equal?(Map.new(ips), gt))
            
            # failures
            in_use = Map.new(Enum.map(view, fn x ->
                {x, get_from_node(x, :in_use)}
            end))
            cnt_false = Enum.count(Map.values(in_use), fn x -> x == false end)
            assert (cnt_false == 1)

            assigned = get_assigned(:orch)
            # group 2 send requests
            Enum.map(ues2, fn x -> send(x, :master_send_req) end)
            Enum.map(Enum.take_random(assigned, 2), fn x -> send(x, :master_terminate) end)

            receive do
            after
            10_000 -> true
            end

            in_use = Map.new(Enum.map(view, fn x ->
                {x, get_from_node(x, :in_use)}
            end))
            cnt_false = Enum.count(Map.values(in_use), fn x -> x == false end)
            assert (cnt_false == 1)
            
            receive do
            after
            20_000 -> true
            end

            # u1 will get ip and u2 will not get ip
            ips = Enum.map(ues2, fn x ->
                {x, (get_from_node(x, :ip) != nil)}
            end)
            gt = %{u3: true, u4: true, u5: true, u6: false}
            assert (Map.equal?(Map.new(ips), gt))
        end)

        handle = Process.monitor(master)
        # Timeout.
        receive do
            {:DOWN, ^handle, _, _, _} -> true
        after
        50_000 -> assert false
        end
    after
        Emulation.terminate()
    end

end