Porcelain
=========

## Prerequisites

Porcelain requires [goon](https://github.com/alco/goon) to work. Get the binary for your OS and put it in your application's working directory or somewhere in your `$PATH`.

## Usage

### Synchronous API

```elixir
## Capture stdout
Porc.call("cat", in: "Hello world!")
#=> {0, "Hello world!", ""}

## Capture stderr
Porc.call("cat -g", in: "Hello world!")
#=> {0, "", "cat: illegal option -- g\nusage: cat [-benstuv] [file ...]\n"}

## Receive output as messages
ref = make_ref
Porc.call("cat", in: "Hello world!", out: {self, ref})
iex> flush
#=> {#Reference<0.0.0.207>, :stdout, "Hello world!"}

## Using files for input and output
{:ok, f} = File.open("data.txt")
{:ok, out_f} = File.open("output.txt", [:write])
Porc.call("cat", in: {:file, f}, out: {:file, out_f})
#=> {0, {:file, #PID<0.48.0>}, ""}
```
```sh
$ cat data.txt
Input from tile
$ cat output.txt
Input from tile
```

### Async API

```elixir
{pid, port} = Porc.spawn("cat", in: :pid, out: :buffer)

Porc.send(pid, "Hello")
Porc.send(pid, "\nWorld")
Porc.send(pid, :eof)

iex> flush
#=> {#PID<0.51.0>, Porc.Process[status: 0, in: :pid, out: "Hello\nWorld", err: nil]}
```

---

See the [tests](https://github.com/alco/porc/blob/master/test/porc_test.exs) for more usage examples.
