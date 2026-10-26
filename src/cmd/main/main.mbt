///|
extern "C" fn proxy_exit(code : Int32) -> Unit = "exit"

///|
fn init {
  // exec must precede the async runtime, which blocks termination signals.
  let args = @env.args()
  if args.length() > 1 &&
    args[1] == "--supervisor" &&
    !@adapter.prepare_ssh_proxy() {
    proxy_exit(127)
  }
  match args {
    [_, "--ssh-transport", lease, .. command] =>
      proxy_exit(@adapter.ssh_transport(command.to_owned(), lease))
    _ => ()
  }
}

///|
async fn main {
  let args = @env.args()
  match args {
    [_, "--ssh-proxy", lease, .. command] =>
      proxy_exit(@adapter.ssh_proxy(command.to_owned(), lease~))
    [_, "--supervisor", directory, workspace] =>
      @adapter.supervisor(directory, initial_workspace=workspace)
    [_, "--supervisor", directory] => @adapter.supervisor(directory)
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
