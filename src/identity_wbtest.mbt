///|
test "workspace names normalize repository URLs and satisfy Devsy limits" {
  for
    (url, slug) in [
      ("https://github.com/org/Glaze.git", "glaze"),
      ("git@example.com:org/some_repo.git", "some-repo"),
      ("ssh://git@example.com/org/My.Repo.git/", "my-repo"),
      ("https://example.com/日本語.git", "repo"),
    ] {
    assert_eq(repository_slug(url), slug)
    for length = 1; length < 120; length = length + 17 {
      let name = workspace_name(
        slug.repeat(length),
        "orca-97494818-ab8d-4df6-9ac4-fe150a9e2d2f",
        "ferret",
      )
      assert_true(valid_workspace_id(name))
      let parts = name.split("-").to_array()
      let suffix = parts[parts.length() - 1]
      assert_eq(suffix, "0a9e2d2f")
      assert_true(
        workspace_animals.contains(parts[parts.length() - 2].to_owned()),
      )
    }
  }
  assert_eq(workspace_animals.length(), 64)
  let seen : Map[String, Bool] = Map([])
  for animal in workspace_animals {
    assert_false(seen.contains(animal))
    seen.set(animal, true)
  }
}

///|
async test "workspace naming skips occupied identities without mutating Devsy" {
  let state : Json = {
    "orcaInstanceId": "orca-97494818-ab8d-4df6-9ac4-fe150a9e2d2f",
    "command": [
      "sh", "-c", "case \"$*\" in *'workspace list'*) printf '[{\"id\":\"repo-alpaca-0a9e2d2f\",\"uid\":\"existing\"}]' ;; *) exit 99 ;; esac",
      "fixture",
    ],
    "devsyEnv": {},
  }
  select_workspace_name(state, "https://example.com/repo.git", start=0)
  assert_eq(required(state, "workspaceId"), "repo-badger-0a9e2d2f")
  let long_slug = "repository".repeat(10)
  let instance = "orca-97494818-ab8d-4df6-9ac4-fe150a9e2d2f"
  let alpaca = workspace_name(long_slug, instance, "alpaca")
  let bat = workspace_name(long_slug, instance, "bat")
  assert_eq(alpaca.replace(old="-alpaca-", new="-bat-"), bat)
}
