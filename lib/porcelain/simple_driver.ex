defmodule Porcelain.Driver.Simple do
  @moduledoc """
  Porcelain driver that offers basic functionality for interacting with
  external programs.

  Users are not supposed to call functions in this module directly. Use
  functions in `Porcelain` instead.

  This driver has two major limitations compared to `Porcelain.Driver.Goon`:

  * the `exec` function does not work with programs that read all input until
    EOF before producing any output. Such programs will hang since Erlang ports
    don't provide any mechanism to indicate the end of input.

    If a program is continuously consuming input and producing output, it could
    work with the `spawn` function, but you'll also have to explicitly close
    the connection with the external program when you're done with it.

  * sending OS signals to external processes is not supported

  """

  alias Porcelain.Driver.Simple.StreamServer

  def exec(cmd, args, opts) do
    do_exec(cmd, args, opts, :noshell)
  end

  def exec_shell(cmd, opts) do
    do_exec(cmd, nil, opts, :shell)
  end


  def spawn(cmd, args, opts) do
    do_spawn(cmd, args, opts, :noshell)
  end

  def spawn_shell(cmd, opts) do
    do_spawn(cmd, nil, opts, :shell)
  end

  ###

  defp do_exec(cmd, args, opts, shell_flag) do
    opts = compile_options(opts)
    exe = find_executable(cmd, shell_flag)
    port = Port.open(exe, port_options(shell_flag, args, opts))
    communicate(port, opts[:async_in], opts[:in], opts[:out], opts[:err])
  end

  defp do_spawn(cmd, args, opts, shell_flag) do
    opts = compile_options(opts)
    exe = find_executable(cmd, shell_flag)
    port = Port.open(exe, port_options(shell_flag, args, opts))

    out_opt = opts[:out]
    if out_opt == :stream do
      {:ok, server} = StreamServer.start()
      out_opt = {:stream, server}
    end

    pid = spawn(fn ->
      communicate(port, true, opts[:in], out_opt, opts[:err])
    end)
    Port.connect(port, pid)
    :erlang.unlink(port)

    out_ret = case out_opt do
      {:stream, server} -> Stream.unfold(server, &read_stream/1)
      _                 -> out_opt
    end
    %Porcelain.Process{port: port, out: out_ret, err: opts[:err]}
  end


  defp compile_options({opts, []}) do
    opts
  end

  defp compile_options({_opts, extra_opts}),
    do: throw "Invalid options: #{inspect extra_opts}"


  def find_executable(cmd, :noshell) do
    if exe=:os.find_executable(:erlang.binary_to_list(cmd)) do
      {:spawn_executable, exe}
    else
      throw "Command not found: #{cmd}"
    end
  end

  def find_executable(cmd, :shell), do: {:spawn, cmd}


  defp port_options(:noshell, args, opts),
    do: [{:args, args} | common_port_options(opts)]

  defp port_options(:shell, _, opts),
    do: common_port_options(opts)


  @common_port_options [:binary, :stream, :exit_status, :use_stdio, :hide]

  defp common_port_options(opts) do
    ret = @common_port_options
    if opts[:err] == :out do
      ret = [:stderr_to_stdout|ret]
    end
    ret
  end

  defp communicate(port, async_input?, input, output, error) do
    input_fun = fn -> send_input(port, input) end
    if async_input? do
      spawn(input_fun)
    else
      input_fun.()
    end
    collect_output(port, output, error)
  end

  defp send_input(port, input) do
    case input do
      iodata when is_binary(iodata) or is_list(iodata) ->
        Port.command(port, input)

      {:file, fid} ->
        pipe_file(fid, port)

      {:path, path} ->
        File.open(path, [:read], fn(fid) ->
          pipe_file(fid, port)
        end)

      null when null in [nil, :receive] ->
        nil

      other -> stream_to_port(other, port)
    end
    ## Send EOF to indicate the end of input or no input
    #Port.command(port, "")
  end

  defp read_stream(server) do
    case StreamServer.get_data(server) do
      nil -> nil
      data -> {data, server}
    end
  end

  # we read files in blocks to avoid excessive memory usage
  @file_block_size 1024*1024

  defp pipe_file(fid, port) do
    Stream.repeatedly(fn -> IO.read(fid, @file_block_size) end)
    |> Stream.take_while(fn
      :eof        -> false
      {:error, _} -> false
      _           -> true
    end)
    |> stream_to_port(port)
  end

  defp stream_to_port(enum, port) do
    Enum.each(enum, fn
      iodata when is_list(iodata) or is_binary(iodata) ->
        Port.command(port, iodata)
      byte ->
        Port.command(port, [byte])
    end)
  end

  defp collect_output(port, output, error) do
    receive do
      { ^port, {:data, data} } ->
        output = process_port_output(output, data)
        collect_output(port, output, error)

      { ^port, {:exit_status, status} } ->
        %Porcelain.Result{
          status: status,
          out: flatten(output),
          err: flatten(error)
        }
    end
  end


  defp process_port_output(nil, _) do
    nil
  end

  defp process_port_output({typ, data}, new_data)
    when typ in [:string, :iodata]
  do
    {typ, [data, new_data]}
  end

  defp process_port_output({:file, fid}=x, data) do
    :ok = IO.write(fid, data)
    x
  end

  defp process_port_output({:path, path}, data) do
    {:ok, fid} = File.open(path, [:write])
    process_port_output({:path, path, fid}, data)
  end

  defp process_port_output({:append, path}, data) do
    {:ok, fid} = File.open(path, [:append])
    process_port_output({:path, path, fid}, data)
  end

  defp process_port_output({:path, _, fid}=x, data) do
    :ok = IO.write(fid, data)
    x
  end

  defp process_port_output({:stream, server}=x, new_data) do
    StreamServer.put_data(server, new_data)
    x
  end

  #defp process_port_output({ pid, ref }=a, in_data, type) when is_pid(pid) do
    #Kernel.send(pid, { ref, type, in_data })
    #a
  #end

  defp flatten(thing) do
    case thing do
      {:string, data}    -> IO.iodata_to_binary(data)
      {:iodata, data}    -> data
      {:path, path, fid} -> File.close(fid); {:path, path}
      {:stream, server}  -> StreamServer.finish(server)
      other              -> other
    end
  end
end
