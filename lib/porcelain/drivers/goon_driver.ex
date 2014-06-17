defmodule Porcelain.Driver.Goon do
  @moduledoc """
  Porcelain driver that offers additional features over the basic one.

  Users are not supposed to call functions in this module directly. Use
  functions in `Porcelain` instead.

  This driver will be used by default if it can locate the external program
  named `goon` in the executable path. If `goon` is not found, Porcelain will
  fall back to the basic driver.

  The additional functionality provided by this driver is as follows:

    * ability to signal EOF to the external program
    * (to be implemented) send an OS signal to the program
    * (to be implemented) more efficient piping of multiple programs

  """

  alias Porcelain.Driver.Common
  alias Common.StreamServer
  @behaviour Common


  @doc false
  def exec(prog, args, opts) do
    do_exec(prog, args, opts, :noshell)
  end

  @doc false
  def exec_shell(prog, opts) do
    do_exec(prog, nil, opts, :shell)
  end


  @doc false
  def spawn(prog, args, opts) do
    do_spawn(prog, args, opts, :noshell)
  end

  @doc false
  def spawn_shell(prog, opts) do
    do_spawn(prog, nil, opts, :shell)
  end

  ###

  defp do_exec(prog, args, opts, shell_flag) do
    opts = Common.compile_options(opts)
    exe = find_executable(prog, opts, shell_flag)
    port = Port.open(exe, port_options(shell_flag, prog, args, opts))
    Common.communicate(port, opts[:in], opts[:out], opts[:err], &process_data/3,
        async_input: opts[:async_in])
  end

  defp do_spawn(prog, args, opts, shell_flag) do
    opts = Common.compile_options(opts)
    exe = find_executable(prog, opts, shell_flag)

    out_opt = opts[:out]
    out_ret = case out_opt do
      :stream ->
        {:ok, server} = StreamServer.start()
        out_opt = {:stream, server}
        Stream.unfold(server, &Common.read_stream/1)

      {atom, ""} when atom in [:string, :iodata] ->
        atom

      _ -> out_opt
    end

    pid = spawn(fn ->
      port = Port.open(exe, port_options(shell_flag, prog, args, opts))
      Common.communicate(port, opts[:in], out_opt, opts[:err], &process_data/3,
          async_input: true, result: opts[:result])
    end)

    %Porcelain.Process{
      pid: pid,
      out: out_ret,
      err: opts[:err],
    }
  end


  @proto_version "0.0"

  @doc false
  defp find_executable(prog, _, :noshell) do
    if :os.find_executable(:erlang.binary_to_list(prog)) do
      {:spawn_executable, Common.find_goon(:noshell)}
    else
      throw "Command not found: #{prog}"
    end
  end

  defp find_executable(prog, opts, :shell) do
    invocation =
      [Common.find_goon(:shell), goon_options(opts), "--", prog]
      |> List.flatten
      |> Enum.join(" ")
      #|> IO.inspect
    {:spawn, invocation}
  end


  defp port_options(:noshell, prog, args, opts) do
    #IO.puts "Choosing port options for :noshell, #{prog} with args #{inspect args} and opts #{inspect opts}"
    args = List.flatten([goon_options(opts), "--", prog, args])
    [{:args, args} | common_port_options(opts)] #|> IO.inspect
  end

  defp port_options(:shell, _, _, opts) do
    common_port_options(opts) #|> IO.inspect
  end

  defp goon_options(opts) do
    ret = []
    if opts[:in] != nil,
      do: ret = ["-in"|ret]
    if opts[:out] == nil,
      do: ret = ["-out", "nil"|ret]
    case opts[:err] do
      nil ->
        ret = ["-err", "nil"|ret]
      :out ->
        flag = if opts[:out], do: "out", else: "nil"
        ret = ["-err", flag|ret]
      _ -> nil
    end
    if dir=opts[:dir],
      do: ret = ["-dir", dir|ret]
    ["-proto", @proto_version|ret]
  end

  defp common_port_options(opts) do
    [{:packet,2}|Common.port_options(opts)]
  end

  ###

  defp process_data(<<?o>> <> data, output, error) do
    {Common.process_port_output(output, data), error}
  end

  defp process_data(<<?e>> <> data, output, error) do
    {output, Common.process_port_output(error, data)}
  end
end
