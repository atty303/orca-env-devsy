///|
test "credential terminology and ordinary URLs remain readable" {
  let progress = Progress::new("test")
  for
    message in [
      "get credentials: credential helper executable not found", "token exchange failed: authorization denied by provider",
      "secret store is locked; password authentication is disabled", "configure SSH_INJECT_GIT_CREDENTIALS: invalid option",
      "request failed: https://example.com/api?region=apne1&page=2", "SSH key discovery failed in /home/developer/.ssh",
      "日本語の認証エラー: credential helper not found",
    ] {
    assert_eq(progress.safe_message(message), Some(message))
  }
}

///|
test "credential values are masked without discarding surrounding causes" {
  let progress = Progress::new("test")
  for
    value in [
      "ERROR Authorization: Bearer fixture-value", "request failed: Authorization: Bearer fixture-value",
      "request failed with token: fixture-value", "error --token fixture-value",
      "error --api-key=fixture-value", "error --password 'fixture-value with spaces'",
      "Cookie=\"fixture-value\"; session=second-value", "https://example.com/path?access%5Ftoken=fixture-value&region=apne1",
      "https://example.com/path?%61ccess_token=fixture-value&region=apne1", "token=fixture-value",
      "token = fixture-value", "api-key:fixture-value", "X-API-Key: fixture-value",
      "Authorization: Bearer fixture-value", "Authorization: Basic fixture-value",
      "credential: fixture-value", "Cookie=fixture-value; session=second-value",
      "Set-Cookie: session=fixture-value", "https://user:fixture-value@example.com/path?region=apne1&signature=second-value",
      "https://example.com/path?key=fixture-value&region=apne1", "key=sk-proj-fixture-value",
      "key:sk-proj-fixture-value", "key\tsk-proj-fixture-value", "github_pat_fixture-value",
      "ghp_fixture-value", "eyJhbGci.fixture-value.signature", "{\"access_token\":\"fixture-value\",\"cause\":\"connection refused\"}",
      "password='fixture-value with spaces'", "token=\"fixture-value \\\" escaped\"",
    ] {
    let message = "cause before; " + value + "; cause after"
    let safe = progress.safe_message(message).unwrap()
    assert_false(safe.contains("fixture-value"), msg=safe)
    assert_false(safe.contains("second-value"), msg=safe)
    assert_true(safe.has_prefix("cause before; "), msg=safe)
    if !value.has_prefix("Cookie") && !value.has_prefix("Set-Cookie") {
      assert_true(safe.has_suffix("; cause after"), msg=safe)
    }
    assert_eq(progress.safe_message(safe), Some(safe))
  }
}

///|
test "workspace info arguments are redacted before diagnostic truncation" {
  let progress = Progress::new("test")
  let encoded = "workspace-data with spaces ".repeat(100)
  let safe = progress
    .safe_message(
      "delete container --workspace-info \"" +
      encoded +
      "\" command failed with exit code 128: original build failure",
    )
    .unwrap()
  assert_false(safe.contains("workspace-data"), msg=safe)
  assert_true(
    safe.contains("command failed with exit code 128: original build failure"),
    msg=safe,
  )
  assert_false(safe.contains("[truncated]"), msg=safe)
}

///|
test "escaped quotes inside workspace info arguments are redacted" {
  let progress = Progress::new("test")
  let encoded = "{\\\"secret\\\": \\\"workspace data\\\"} ".repeat(100)
  let second_encoded = "second workspace data ".repeat(100)
  let safe = progress
    .safe_message(
      "delete container --workspace-info \"" +
      encoded +
      "\" --workspace-info \"" +
      second_encoded +
      "\" command failed with exit code 128: original build failure",
    )
    .unwrap()
  assert_false(safe.contains("workspace data"), msg=safe)
  assert_false(safe.contains("second workspace data"), msg=safe)
  assert_true(
    safe.contains("command failed with exit code 128: original build failure"),
    msg=safe,
  )
  assert_false(safe.contains("[truncated]"), msg=safe)
}

///|
test "failure detail preserves a bounded redacted stderr tail" {
  let environment : Map[String, String] = Map([
    ("GITHUB_TOKEN", "fixture-secret"),
  ])
  let progress = Progress::new("test", environment~)
  let detail = progress.failure_detail(
    stderr_tail="provider failed: token=fixture-secret\nworkspace-create: failed (exit 128)",
  )
  assert_true(detail.contains("provider failed: token=[redacted]"), msg=detail)
  assert_true(
    detail.contains("workspace-create: failed (exit 128)"),
    msg=detail,
  )
  assert_false(detail.contains("fixture-secret"), msg=detail)
  let bounded = Progress::new("test").failure_detail(
    stderr_tail=[
      "line 0", "line 1", "line 2", "line 3", "line 4", "line 5", "line 6", "line 7",
      "line 8", "line 9",
    ].join("\n"),
  )
  assert_false(bounded.contains("line 0"), msg=bounded)
  assert_true(bounded.contains("line 9"), msg=bounded)
  assert_true(
    bounded.contains("error details incomplete or truncated"),
    msg=bounded,
  )
  let binary = Progress::new("test").failure_detail(
    stderr_tail="\u{fffd} private-binary-secret",
  )
  assert_false(binary.contains("private-binary-secret"), msg=binary)
  assert_true(
    binary.contains("error details incomplete or truncated"),
    msg=binary,
  )
}
