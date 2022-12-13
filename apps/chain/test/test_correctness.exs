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
                    :orch,
                    10_000,
                    1000
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
            100_000
        )

        a = spawn_server(:a)
        b = spawn_server(:b)
        c = spawn_server(:c)
        d = spawn_server(:d)
        e = spawn_server(:e)

        orch = spawn(:orch, fn -> FTC.start(base_config) end)
        gnb = spawn(:gnb, fn -> FTC.GNB.startup(FTC.GNB.new_gNB(:orch, 20)) end)

        client = spawn(:client, fn ->
            client = FTC.UE.new_client(:client, :gnb)

            receive do
            after
            5_000 -> true
            end
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
end