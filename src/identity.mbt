///|
let workspace_animals : Array[String] = [
  "alpaca", "badger", "bat", "bear", "beaver", "bison", "boar", "bobcat", "camel",
  "caribou", "cat", "cheetah", "cobra", "cod", "cougar", "coyote", "crab", "crane",
  "crow", "deer", "dingo", "dolphin", "dove", "duck", "eagle", "egret", "elk", "falcon",
  "ferret", "finch", "fox", "frog", "gecko", "goat", "goose", "hare", "hawk", "heron",
  "ibis", "ibex", "jaguar", "koala", "lark", "lemur", "lion", "lynx", "marten", "mole",
  "moose", "newt", "otter", "owl", "panda", "puma", "quail", "raven", "robin", "seal",
  "shark", "tiger", "trout", "whale", "wolf", "wren",
]

///|
fn repository_slug(repository : String) -> String {
  let raw_name = repository
    .trim_end(chars="/")
    .split("/")
    .to_array()
    .last()
    .unwrap()
    .split(":")
    .to_array()
    .last()
    .unwrap()
    .to_owned()
  let name = raw_name
    .strip_suffix(".git")
    .unwrap_or(raw_name)
    .to_owned()
    .to_lower()
  let slug = StringBuilder()
  let mut separator = false
  let mut started = false
  for c in name {
    if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') {
      if separator && started {
        slug.write_string("-")
      }
      slug.write_char(c)
      separator = false
      started = true
    } else {
      separator = true
    }
  }
  let slug = slug.to_string()
  if slug == "" {
    "repo"
  } else {
    slug
  }
}

///|
fn workspace_name(slug : String) -> String raise {
  let alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
  for attempt = 0; attempt < 32; attempt = attempt + 1 {
    guard @env.rand(3) is Some(bytes) else {
      raise AdapterError("Workspace naming requires platform randomness")
    }
    if bytes[1].to_int() >= 252 || bytes[2].to_int() >= 252 {
      continue
    }
    let animal = workspace_animals[bytes[0].to_int() %
      workspace_animals.length()]
    let limit = 48 - animal.length() - 4
    let prefix = if slug.length() > limit {
      slug[0:limit].to_owned().trim_end(chars="-").to_owned()
    } else {
      slug
    }
    return prefix +
      "-" +
      animal +
      "-" +
      alphabet.get_char(bytes[1].to_int() % 36).unwrap().to_string() +
      alphabet.get_char(bytes[2].to_int() % 36).unwrap().to_string()
  }
  raise AdapterError("Unable to generate workspace name")
}

///|
async fn workspace_creation_lock() -> @fs.File {
  let directory = adapter_state_home()
  @fs.mkdir(directory, recursive=true, permission=0o700, allow_exist=true)
  let lock = @fs.open(
    directory + "/create.lock",
    mode=ReadWrite,
    create_mode=OpenOrCreate,
    permission=0o600,
  )
  errdefer lock.close()
  @async.with_timeout(600000, async fn() {
    while !lock.try_lock(Exclusive) {
      @async.sleep(100)
    }
  })
  lock
}

///|
async fn select_workspace_name(
  state : Json,
  repository : String,
  generate~ : (String) -> String raise = workspace_name,
) -> Unit {
  let slug = repository_slug(repository)
  for attempt = 0; attempt < 64; attempt = attempt + 1 {
    let id = generate(slug)
    set_field(state, "workspaceId", Json::string(id))
    let occupied = workspace(state) is Some(_)
    save_diagnostic(
      "workspace-name",
      if occupied {
        "collision"
      } else {
        "selected"
      },
      attempt=attempt + 1,
      source=IdentitySelection(slug, id),
    )
    if !occupied {
      return
    }
  }
  raise AdapterError("Unable to reserve an unused workspace name")
}
