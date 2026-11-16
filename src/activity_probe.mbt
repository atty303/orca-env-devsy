///|
fn activity_from_worktree_ps(response : Json) -> Json raise {
  guard field(response, "ok") == Some(Json::boolean(true)) &&
    field(response, "result") is Some(result) &&
    field(result, "worktrees") is Some(Json::Array(worktrees)) else {
    raise AdapterError("Incomplete Orca worktree activity response")
  }
  let evidence : Array[Json] = []
  let mut active = false
  for worktree in worktrees {
    guard field(worktree, "agents") is Some(Json::Array(agents)) else {
      raise AdapterError("Invalid Orca worktree activity response")
    }
    for agent in agents {
      guard field(agent, "state") is Some(Json::String(state)) else {
        raise AdapterError("Invalid Orca agent activity response")
      }
      if state == "working" {
        active = true
      }
      evidence.push({ "state": state })
    }
  }
  {
    "schemaVersion": 1,
    "activity": if active {
      "active"
    } else {
      "idle"
    },
    "truncated": field(result, "truncated").unwrap_or(Json::null()),
    "agents": Json::array(evidence),
  }
}
