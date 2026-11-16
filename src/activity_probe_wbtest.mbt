///|
test "worktree activity depends on working agents" {
  for state in ["done", "waiting", "blocked", "working"] {
    let response : Json = {
      "ok": true,
      "result": {
        "truncated": false,
        "worktrees": [{ "agents": [{ "state": state, "prompt": "private" }] }],
      },
    }
    let result = activity_from_worktree_ps(response)
    assert_eq(
      field(result, "activity"),
      Some(Json::string(if state == "working" { "active" } else { "idle" })),
    )
    assert_false(result.stringify().contains("private"))
  }
}

///|
test "incomplete worktree activity responses fail" {
  for
    response in [
      ({ "ok": false } : Json),
      { "ok": true, "result": { "truncated": false, "worktrees": [{}] } },
    ] {
    let failed = try {
      ignore(activity_from_worktree_ps(response))
      false
    } catch {
      _ => true
    }
    assert_true(failed)
  }
}

///|
test "truncated worktree listings use available agents" {
  let response : Json = {
    "ok": true,
    "result": { "truncated": true, "worktrees": [] },
  }
  let result = activity_from_worktree_ps(response)
  assert_eq(field(result, "activity"), Some(Json::string("idle")))
  assert_eq(field(result, "truncated"), Some(Json::boolean(true)))
}
