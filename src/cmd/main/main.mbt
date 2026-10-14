///|
async fn main {
  let args = @env.args()
  match args {
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
