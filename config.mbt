///|
pub suberror ConfigError {
  InvalidConfig(String)
} derive(Debug)

///|
pub enum Connection {
  Server
  Ssh
} derive(Eq, Debug)

///|
pub struct Settings {
  connection : Connection
  command : Array[String]
  home : String?
  context : String?
  build_ref : String?
  up_args : Array[String]
  codex_auth : Bool
} derive(Eq, Debug)

///|
fn string_field(
  value : Json,
  name : String,
  location : String,
) -> String? raise ConfigError {
  match field(value, name) {
    None => None
    Some(Json::String(text)) => Some(text)
    _ => raise InvalidConfig("\{location}.\{name} must be a string")
  }
}

///|
fn object_field(
  value : Json,
  name : String,
  location : String,
) -> Json raise ConfigError {
  match field(value, name) {
    None => Json::empty_object()
    Some(Json::Object(_) as object) => object
    _ => raise InvalidConfig("\{location}.\{name} must be a mapping")
  }
}

///|
fn args_field(
  value : Json,
  location : String,
) -> Array[String] raise ConfigError {
  match field(value, "upArgs") {
    None => []
    Some(Json::Array(items)) =>
      items.map(item => {
        match item {
          Json::String(text) => text
          _ => raise InvalidConfig("\{location}.upArgs must contain strings")
        }
      })
    _ => raise InvalidConfig("\{location}.upArgs must be an array")
  }
}

///|
fn command_field(
  value : Json,
  location : String,
) -> Array[String]? raise ConfigError {
  match field(value, "command") {
    None => None
    Some(Json::Array(items)) => {
      guard items.length() > 0 else {
        raise InvalidConfig("\{location}.command must be a nonempty array")
      }
      let command = items.mapi((index, item) => {
        match item {
          Json::String(text) => {
            guard !text.contains("\u0000") && (index != 0 || text != "") else {
              raise InvalidConfig(
                "\{location}.command[\{index}] must not contain NUL or have an empty executable",
              )
            }
            text
          }
          _ =>
            raise InvalidConfig(
              "\{location}.command[\{index}] must be a string",
            )
        }
      })
      Some(command)
    }
    _ => raise InvalidConfig("\{location}.command must be an array of strings")
  }
}

///|
pub fn interpolate(
  value : String,
  lookup : (String) -> String?,
  location : String,
) -> String raise ConfigError {
  let output = StringBuilder()
  let mut remaining = value
  while remaining.split_once("${") is Some((prefix, expression)) {
    output.write_string(prefix.to_owned())
    guard expression.split_once("}") is Some((variable, suffix)) else {
      raise InvalidConfig("\{location}: unterminated environment variable")
    }
    let text = variable.to_owned()
    let required = text.has_suffix("?")
    let name = if required { text[:text.length() - 1].to_owned() } else { text }
    let characters = name.to_array()
    guard characters.length() > 0 &&
      !(characters[0] >= '0' && characters[0] <= '9') &&
      characters
      .iter()
      .all(char => {
        char == '_' ||
        (char >= 'a' && char <= 'z') ||
        (char >= 'A' && char <= 'Z') ||
        (char >= '0' && char <= '9')
      }) else {
      raise InvalidConfig("\{location}: invalid environment variable reference")
    }
    match lookup(name) {
      Some(resolved) => output.write_string(resolved)
      None if required =>
        raise InvalidConfig(
          "\{location}: environment variable \{name} is not defined",
        )
      None => ()
    }
    remaining = suffix.to_owned()
  }
  output.write_string(remaining)
  output.to_string()
}

///|
pub fn resolve_settings(
  document : Json,
  recipe_id : String,
  lookup : (String) -> String?,
) -> Settings raise ConfigError {
  let common = object_field(document, "devsy", "orca.yaml")
  let recipes = match field(document, "environmentRecipes") {
    Some(Json::Array(items)) => items
    _ => raise InvalidConfig("orca.yaml.environmentRecipes must be an array")
  }
  let selected = recipes.filter(recipe => {
    field(recipe, "id") == Some(Json::string(recipe_id))
  })
  guard selected.length() == 1 else {
    raise InvalidConfig(
      "Expected exactly one environment recipe named \{recipe_id}",
    )
  }
  let specific = object_field(
    selected[0],
    "devsy",
    "environmentRecipes.\{recipe_id}",
  )
  let profile_name = match string_field(specific, "profile", "recipe.devsy") {
    Some(name) => Some(name)
    None => string_field(common, "profile", "devsy")
  }
  let profiles = object_field(common, "profiles", "devsy")
  let mut profile_location = "devsy.profiles"
  let profile = match profile_name {
    Some(raw_name) => {
      let name = interpolate(raw_name, lookup, "devsy.profile")
      profile_location = "devsy.profiles." + name
      match field(profiles, name) {
        Some(Json::Object(_) as value) => value
        _ => raise InvalidConfig("Unknown devsy profile")
      }
    }
    None => Json::empty_object()
  }
  let layers = [common, profile, specific]
  let mut command = ["devsy"]
  let mut home = None
  let mut context = None
  let mut build_ref = None
  let mut connection = None
  let mut codex_auth = false
  let args = []
  for index, layer in layers {
    let location = [
        "devsy",
        profile_location,
        "environmentRecipes." + recipe_id + ".devsy",
      ][index]
    if command_field(layer, location) is Some(raw) {
      let expanded = raw.mapi((argument_index, argument) => {
        interpolate(argument, lookup, "\{location}.command[\{argument_index}]")
      })
      let value = Json::empty_object()
      set_field(value, "command", Json::array(expanded.map(Json::string)))
      command = command_field(value, location).unwrap()
    }
    for
      pair in [
        ("home", string_field(layer, "home", location)),
        ("context", string_field(layer, "context", location)),
        ("buildRef", string_field(layer, "buildRef", location)),
        ("connection", string_field(layer, "connection", location)),
      ] {
      let (name, value) = pair
      if value is Some(raw) {
        let expanded = interpolate(raw, lookup, "\{location}.\{name}")
        match name {
          "home" => home = Some(expanded)
          "context" => context = Some(expanded)
          "buildRef" => build_ref = Some(expanded)
          _ => connection = Some(expanded)
        }
      }
    }
    for argument_index, argument in args_field(layer, location) {
      args.push(
        interpolate(argument, lookup, "\{location}.upArgs[\{argument_index}]"),
      )
    }
    let addons = object_field(layer, "addons", location)
    match field(addons, "codexAuth") {
      None => ()
      Some(Json::True) => codex_auth = true
      Some(Json::False) => codex_auth = false
      _ => raise InvalidConfig("\{location}.addons.codexAuth must be a boolean")
    }
  }
  let connection = match connection {
    Some("orca-server") => Server
    Some("ssh") => Ssh
    _ =>
      raise InvalidConfig(
        "devsy.connection must explicitly select orca-server or ssh",
      )
  }
  { connection, command, home, context, build_ref, up_args: args, codex_auth, }
}

///|
fn field(value : Json, name : String) -> Json? {
  if value is Json::Object(object) {
    object.get(name)
  } else {
    None
  }
}

///|
pub extend Connection with Eq::{equal, not_equal}

///|
pub extend Settings with Eq::{equal, not_equal}

///|
pub extend ConfigError with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend Connection with @debug.Debug::{to_repr}

///|
pub extend Settings with @debug.Debug::{to_repr}
