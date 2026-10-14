///|
test "environment references preserve argument boundaries and required semantics" {
  let env = { "EMPTY": "", "VALUE": "two words; $(ignored)" }
  assert_eq(
    interpolate("${VALUE}", name => env.get(name), "upArgs"),
    "two words; $(ignored)",
  )
  assert_eq(interpolate("${MISSING}", name => env.get(name), "upArgs"), "")
  assert_eq(interpolate("${EMPTY?}", name => env.get(name), "upArgs"), "")
  try {
    let _ = interpolate("${MISSING?}", name => env.get(name), "upArgs")
    fail("required reference should fail")
  } catch {
    InvalidConfig(message) => assert_true(message.contains("MISSING"))
    _ => fail("unexpected error")
  }
}

///|
test "one selected profile overrides common settings and appends native arguments" {
  let text =
    #|{"devsy":{"connection":"orca-server","profile":"unused","upArgs":["--secret","agent-key"],"profiles":{"unused":{"connection":"ssh"},"chosen":{"context":"${CTX?}","upArgs":["--provider","docker"]}}},"environmentRecipes":[{"id":"test","devsy":{"profile":"chosen","upArgs":["--provider-option","SIZE=large"]}}]}
  let input = @json.parse(text)
  let actual = resolve_settings(input, "test", name => {
    if name == "CTX" {
      Some("example")
    } else {
      None
    }
  })
  assert_eq(actual.connection, Server)
  assert_eq(actual.context, Some("example"))
  assert_eq(actual.up_args, [
    "--secret", "agent-key", "--provider", "docker", "--provider-option", "SIZE=large",
  ])
}

///|
async test "SSH command quoting escapes every quote and never evaluates substitutions" {
  let text = "first' second' $(printf evaluated)"
  let (status, output, _) = @process.collect_output("/bin/sh", [
    "-c",
    "printf %s " + quote(text),
  ])
  assert_eq(status, 0)
  assert_eq(output.text(), text)
}

///|
test "command replaces each selected layer and expands individual arguments" {
  let document = @json.parse(
    (
      #|{"devsy":{"connection":"ssh","command":["common"],"profiles":{"chosen":{"command":["${EXEC?}","","two words; $(ignored)","${MISSING}"]},"unused":{"command":false}}},"environmentRecipes":[{"id":"test","devsy":{}}]}
    ),
  )
  guard field(document, "environmentRecipes") is Some(Json::Array(recipes)) else {
    fail("missing recipes")
  }
  let recipe = recipes[0]
  let specific = field(recipe, "devsy").unwrap()
  let lookup = fn(name) { if name == "EXEC" { Some("launcher") } else { None } }
  assert_eq(resolve_settings(document, "test", lookup).command, ["common"])
  set_field(specific, "profile", Json::string("chosen"))
  assert_eq(resolve_settings(document, "test", lookup).command, [
    "launcher", "", "two words; $(ignored)", "",
  ])
  set_field(specific, "command", ["recipe", "fixed"])
  assert_eq(resolve_settings(document, "test", lookup).command, [
    "recipe", "fixed",
  ])
}

///|
test "invalid commands report their layer and element without exposing values" {
  for
    invalid in [
      Json::null(),
      Json::string("devsy"),
      [],
      [""],
      ["devsy", 1],
      ["${MISSING}"],
      ["devsy", "a\u0000b"],
      ["devsy", "${REQUIRED?}"],
    ] {
    let document : Json = {
      "devsy": {
        "connection": "ssh",
        "profiles": { "selected": { "command": invalid } },
      },
      "environmentRecipes": [
        { "id": "test", "devsy": { "profile": "selected" } },
      ],
    }
    try {
      ignore(resolve_settings(document, "test", _ => None))
      fail("invalid command accepted")
    } catch {
      InvalidConfig(message) =>
        assert_true(message.contains("devsy.profiles.selected.command"))
      _ => fail("unexpected error")
    }
  }
}
