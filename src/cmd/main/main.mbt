///|
extern "C" fn proxy_exit(code : Int32) -> Unit = "exit"

///|
fn init {
  // exec must precede the async runtime, which blocks termination signals.
  match @env.args() {
    [_, "--ssh-transport", .. command] =>
      proxy_exit(@adapter.ssh_transport(command.to_owned()))
    _ => ()
  }
}

///|
async fn main {
  let args = @env.args()
  match args {
    [_, "--ssh-proxy", lease, .. command] =>
      proxy_exit(@adapter.ssh_proxy(command.to_owned(), lease~))
    [_, "--tunnel-worker", directory] => @adapter.tunnel_worker(directory)
    [_, "--version"] =>
      @stdio.stdout.write("orca-env-devsy " + @adapter.version + "\n")
    [_, "reconnect"] => @adapter.reconnect_all()
    [_, "reconnect", "--receipt"] => @adapter.execute("reconnect")
    [_, "create" | "resume" | "suspend" | "destroy" as mode] =>
      @adapter.execute(mode)
    [_, "--help"] =>
      @stdio.stdout.write(
        "Usage: orca-env-devsy <create|resume|suspend|destroy|reconnect [--receipt]>\n",
      )
    _ => @adapter.usage_error()
  }
}
