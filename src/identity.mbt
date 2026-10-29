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
fn workspace_name(
  slug : String,
  instance_id : String,
  animal : String,
) -> String {
  let suffix = instance_id[if instance_id.length() > 8 {
    instance_id.length() - 8
  } else {
    0
  }:].to_owned()
  let longest_animal = workspace_animals.fold(init=0, fn(max, name) {
    if name.length() > max {
      name.length()
    } else {
      max
    }
  })
  let limit = 48 - longest_animal - suffix.length() - 2
  let prefix = if slug.length() > limit {
    slug[0:limit].to_owned().trim_end(chars="-").to_owned()
  } else {
    slug
  }
  return prefix + "-" + animal + "-" + suffix
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
  start? : Int32,
) -> Unit {
  let slug = repository_slug(repository)
  let offset = match start {
    Some(value) => value
    None => {
      guard @env.rand(1) is Some(bytes) else {
        raise AdapterError("Workspace naming requires platform randomness")
      }
      bytes[0].to_int() % workspace_animals.length()
    }
  }
  for attempt = 0; attempt < workspace_animals.length(); attempt = attempt + 1 {
    let animal = workspace_animals[(offset + attempt) %
      workspace_animals.length()]
    let id = workspace_name(slug, required(state, "orcaInstanceId"), animal)
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
