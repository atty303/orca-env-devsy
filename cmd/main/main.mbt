///|
async fn main {
  let args = @env.args()
  match args {
    [_, "--version"] =>
      @stdio.stdout.write("orca-env-devsy " + @adapter.version + "\n")
    [_, "create" | "resume" | "suspend" | "destroy" | "reconnect" as mode] =>
      @adapter.execute(mode)
    [_, "--help"] =>
      @stdio.stdout.write(
        "Usage: orca-env-devsy <create|resume|suspend|destroy|reconnect>\n",
      )
    _ => @adapter.usage_error()
  }
}
