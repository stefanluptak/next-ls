defmodule NextLs.RuntimeTest do
  use ExUnit.Case, async: true

  import NextLS.Support.Utils

  alias NextLS.Runtime

  require Logger

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "mix.exs"), mix_exs())
    File.mkdir_p!(Path.join(tmp_dir, "lib"))

    File.write!(Path.join(tmp_dir, "lib/bar.ex"), """
    defmodule Bar do
      defstruct [:foo]

      def foo(arg1) do
      end
    end
    """)

    me = self()

    {:ok, logger} =
      Task.start_link(fn ->
        recv = fn recv ->
          receive do
            {:"$gen_cast", msg} -> send(me, msg)
          end

          recv.(recv)
        end

        recv.(recv)
      end)

    on_init = fn msg -> send(me, msg) end

    on_exit(&flush_messages/0)

    [logger: logger, cwd: Path.absname(tmp_dir), on_init: on_init]
  end

  describe "errors" do
    # FIXME(zachallaun): make these not flaky on CI
    @describetag :pending
    test "emitted on crash during initialization",
         %{tmp_dir: tmp_dir, logger: logger, cwd: cwd, on_init: on_init} do
      # obvious syntax error
      bad_mix_exs = String.replace(mix_exs(), "defmodule", "")
      File.write!(Path.join(tmp_dir, "mix.exs"), bad_mix_exs)

      start_supervised!({Registry, keys: :duplicate, name: RuntimeTest.Registry})

      tvisor = start_supervised!(Task.Supervisor)

      start_supervised!(
        {Runtime,
         task_supervisor: tvisor,
         name: "my_proj",
         on_initialized: on_init,
         working_dir: cwd,
         uri: "file://#{cwd}",
         parent: self(),
         logger: logger,
         db: :some_db,
         mix_env: "dev",
         mix_target: "host",
         registry: RuntimeTest.Registry},
        restart: :temporary
      )

      assert_receive {:error, :portdown}

      assert_receive {:log, :log, log_msg}
      assert log_msg =~ "syntax error"

      assert_receive {:log, :error, error_msg}
      assert error_msg =~ "{:shutdown, :portdown}"
    end

    test "emitted on crash after initialization",
         %{logger: logger, cwd: cwd, on_init: on_init} do
      start_supervised!({Registry, keys: :duplicate, name: RuntimeTest.Registry})

      tvisor = start_supervised!(Task.Supervisor)

      pid =
        start_supervised!(
          {Runtime,
           task_supervisor: tvisor,
           name: "my_proj",
           on_initialized: on_init,
           working_dir: cwd,
           uri: "file://#{cwd}",
           parent: self(),
           logger: logger,
           db: :some_db,
           mix_env: "dev",
           mix_target: "host",
           registry: RuntimeTest.Registry},
          restart: :temporary
        )

      assert_receive :ready

      assert {:ok, {:badrpc, :nodedown}} = Runtime.call(pid, {System, :halt, [1]})

      assert_receive {:log, :error, error_msg}
      assert error_msg =~ "{:shutdown, :nodedown}"
    end
  end

  describe "call/2" do
    test "responds with an ok tuple if the runtime has initialized",
         %{logger: logger, cwd: cwd, on_init: on_init} do
      start_supervised!({Registry, keys: :duplicate, name: RuntimeTest.Registry})
      tvisor = start_supervised!(Task.Supervisor)

      pid =
        start_supervised!(
          {Runtime,
           name: "my_proj",
           on_initialized: on_init,
           task_supervisor: tvisor,
           working_dir: cwd,
           uri: "file://#{cwd}",
           parent: self(),
           logger: logger,
           db: :some_db,
           mix_env: "dev",
           mix_target: "host",
           registry: RuntimeTest.Registry}
        )

      Process.link(pid)

      assert_receive :ready

      assert {:ok, "\"hi\""} = Runtime.call(pid, {Kernel, :inspect, ["hi"]})
    end

    test "responds with an error when the runtime hasn't initialized", %{logger: logger, cwd: cwd, on_init: on_init} do
      start_supervised!({Registry, keys: :duplicate, name: RuntimeTest.Registry})

      tvisor = start_supervised!(Task.Supervisor)

      pid =
        start_supervised!(
          {Runtime,
           task_supervisor: tvisor,
           name: "my_proj",
           on_initialized: on_init,
           working_dir: cwd,
           uri: "file://#{cwd}",
           parent: self(),
           logger: logger,
           db: :some_db,
           mix_env: "dev",
           mix_target: "host",
           registry: RuntimeTest.Registry}
        )

      Process.link(pid)

      assert {:error, :not_ready} = Runtime.call(pid, {IO, :puts, ["hi"]})
    end
  end

  describe "compile/1" do
    test "compiles the project and returns diagnostics",
         %{logger: logger, cwd: cwd, on_init: on_init} do
      start_supervised!({Registry, keys: :duplicate, name: RuntimeTest.Registry})

      tvisor = start_supervised!(Task.Supervisor)

      pid =
        start_link_supervised!(
          {Runtime,
           name: "my_proj",
           on_initialized: on_init,
           task_supervisor: tvisor,
           working_dir: cwd,
           uri: "file://#{cwd}",
           parent: self(),
           logger: logger,
           db: :some_db,
           mix_env: "dev",
           mix_target: "host",
           registry: RuntimeTest.Registry}
        )

      assert_receive :ready

      file = Path.join(cwd, "lib/bar.ex")

      assert [
               %Mix.Task.Compiler.Diagnostic{
                 file: ^file,
                 severity: :warning,
                 message:
                   "variable \"arg1\" is unused (if the variable is not meant to be used, prefix it with an underscore)",
                 position: position,
                 compiler_name: "Elixir",
                 details: nil
               }
             ] = Runtime.compile(pid)

      if Version.match?(System.version(), ">= 1.15.0") do
        assert position == {4, 11}
      else
        assert position == 4
      end

      File.write!(file, """
      defmodule Bar do
        def foo(arg1) do
          arg1
        end
      end
      """)

      assert [] == Runtime.compile(pid)
    end

    test "responds with an error when the runtime isn't ready", %{logger: logger, cwd: cwd, on_init: on_init} do
      start_supervised!({Registry, keys: :duplicate, name: RuntimeTest.Registry})

      tvisor = start_supervised!(Task.Supervisor)

      pid =
        start_supervised!(
          {Runtime,
           task_supervisor: tvisor,
           name: "my_proj",
           on_initialized: on_init,
           working_dir: cwd,
           uri: "file://#{cwd}",
           parent: self(),
           logger: logger,
           db: :some_db,
           mix_env: "dev",
           mix_target: "host",
           registry: RuntimeTest.Registry}
        )

      Process.link(pid)

      assert {:error, :not_ready} = Runtime.compile(pid)
    end
  end

  defp flush_messages do
    receive do
      _ -> flush_messages()
    after
      0 -> :ok
    end
  end
end
