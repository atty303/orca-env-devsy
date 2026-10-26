///|
extern "C" fn proxy_exit(code : Int32) -> Unit = "exit"

///|
fn init {
  // exec must precede the async runtime, which blocks termination signals.
  let args = @env.args()
  if args.length() > 1 &&
    args[1] == "--ssh-proxy-worker" &&
    !@adapter.prepare_ssh_proxy() {
    proxy_exit(127)
  }
  match args {
    [_, "--ssh-transport", .. command] =>
      proxy_exit(@adapter.ssh_transport(command.to_owned()))
    _ => ()
  }
}

///|
async fn main {
  let args = @env.args()
  match args {
    [_, "--ssh-proxy-worker", lease, parent, .. command] =>
      proxy_exit(@adapter.ssh_proxy_worker(command.to_owned(), lease~, parent~))
    [_, "--ssh-proxy", lease, .. command] =>
      proxy_exit(@adapter.ssh_proxy(command.to_owned(), lease~))
    [_, "--tunnel-worker", directory] => @adapter.tunnel_worker(directory)
    [_, "--version"] =>
      @stdio.stdout.write("orca-env-devsy " + @adapter.version + "\n")
    [_, "recover"] => @adapter.recover_all()
    [_, "restart"] => @adapter.recover_all(restart=true)
    [
      _,
      "recipe",
      "create"
      | "resume"
      | "suspend"
      | "destroy"
      | "recover"
      | "restart" as mode,
    ] => @adapter.execute(mode)
    [_, "status" | "stop" | "resume" as mode, .. options] =>
      @adapter.bulk(mode, options.to_owned())
    [_, "--help"] => @stdio.stdout.write(@adapter.usage)
    _ => @adapter.usage_error()
  }
}
