///|
let progress_started : UInt64 = @env.now()

///|
fn seconds(milliseconds : UInt64) -> String {
  let tenths = milliseconds / 100UL
  "\{tenths / 10UL}.\{tenths % 10UL}s"
}

///|
fn progress_timing(started : UInt64) -> String {
  let now = @env.now()
  seconds(now - started) + ", elapsed " + seconds(now - progress_started)
}

///|
priv struct ProgressSink {
  lock : @async.Mutex
  mut available : Bool
}

///|
let progress_sink : ProgressSink = {
  lock: @async.Mutex::Mutex(),
  available: true,
}

///|
async fn progress_message(message : String) -> Unit {
  progress_sink.lock.acquire()
  defer progress_sink.lock.release()
  if !progress_sink.available {
    return
  }
  let clock = @env.now() / 1000UL % 86400UL
  let pad = fn(value : UInt64) {
    if value < 10UL {
      "0" + value.to_string()
    } else {
      value.to_string()
    }
  }
  @stdio.stderr.write(
    pad(clock / 3600UL) +
    ":" +
    pad(clock / 60UL % 60UL) +
    ":" +
    pad(clock % 60UL) +
    " " +
    message +
    "\n",
  ) catch {
    _ => {
      progress_sink.available = false
      save_diagnostic("progress-output", "failed", error_type="progress_io")
    }
  }
}

///|
fn devsy_progress_stage(stage : String) -> Bool {
  [
    "workspace-create", "workspace-create-full", "workspace-resume", "workspace-stop",
    "workspace-delete", "create-cleanup",
  ].contains(stage)
}

///|
fn phase_label(phase : String) -> String? {
  match phase {
    "cloning_repository" => Some("Clone repository")
    "resolving_config" => Some("Resolve devcontainer config")
    "initialize_command" => Some("Initialize")
    "preparing_devcontainer" => Some("Prepare devcontainer")
    "building_image" => Some("Build image")
    "starting_container" => Some("Start container")
    "injecting_agent" => Some("Install Devsy agent")
    "running_lifecycle_hook" => Some("Run lifecycle hooks")
    "waiting_for" => Some("Wait for container")
    "running_command" => Some("Run command")
    "configuring_workspace" => Some("Configure workspace")
    "configuring_ssh" => Some("Configure SSH")
    "starting_ssh_tunnel" => Some("Start SSH tunnel")
    "launching_ide" => Some("Prepare IDE")
    "stopping_workspace" => Some("Stop workspace")
    "deleting_workspace" => Some("Delete workspace")
    "rebuilding_workspace" => Some("Rebuild workspace")
    "resetting_workspace" => Some("Reset workspace")
    "importing_workspace" => Some("Import workspace")
    "ready" => Some("Workspace ready")
    "failed" => Some("Workspace failed")
    "installing_provider" => Some("Install provider")
    "resolving_options" => Some("Resolve provider options")
    "running_init" => Some("Initialize provider")
    _ => None
  }
}

///|
priv struct Progress {
  stage : String
  operations : Map[String, UInt64]
  builds : Map[String, String]
  secrets : Array[String]
  mut phase_count : Int32
  mut private_key : Bool
  mut classic_build : Bool
}

///|
fn sensitive_name(name : String) -> Bool {
  let name = name.to_lower()
  [
    "password", "passwd", "token", "secret", "api_key", "apikey", "auth", "credential",
    "private_key", "access_key", "cookie", "fnox_age_key",
  ]
  .iter()
  .any(marker => name.contains(marker))
}

///|
fn Progress::new(stage : String) -> Progress {
  let secrets = []
  for name, value in @env.get_env_vars() {
    if sensitive_name(name) && value != "" {
      secrets.push(value)
      // Multiline credentials must also be masked in line-oriented output.
      for part in value.split("\n") {
        if part.trim() != "" {
          secrets.push(part.to_owned())
        }
      }
    }
  }
  secrets.sort_by((a, b) => b.length().compare(a.length()))
  {
    stage,
    operations: {},
    builds: {},
    secrets,
    phase_count: 0,
    private_key: false,
    classic_build: false,
  }
}

///|
fn terminal_text(text : String) -> String? {
  let output = @buffer.Buffer(size_hint=256)
  let mut state = 0
  for c in text.iter() {
    match state {
      0 =>
        if c == '\u001b' {
          state = 1
        } else if c.to_int() < 32 && c != '\t' {
          return None
        } else {
          output.write_char_utf8(c)
        }
      1 =>
        if c == '[' {
          state = 2
        } else if c == ']' {
          state = 3
        } else {
          return None
        }
      2 => if c >= '@' && c <= '~' { state = 0 }
      3 => if c == '\u0007' { state = 0 } else if c == '\u001b' { state = 4 }
      _ => if c == '\\' { state = 0 } else { state = 3 }
    }
  }
  if state != 0 {
    None
  } else {
    Some(@utf8.decode_lossy(output.to_bytes()))
  }
}

///|
fn credential_prefix(text : String, prefix : String) -> Bool {
  let parts = text.split(prefix).to_array()
  for i in 0..<(parts.length() - 1) {
    let previous = parts[i].iter().last()
    let boundary = match previous {
      None => true
      Some(c) => !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_')
    }
    if boundary {
      return true
    }
  }
  false
}

///|
fn Progress::safe_message(self : Progress, text : String) -> String? {
  guard terminal_text(text) is Some(text) else { return None }
  let lower = text.to_lower()
  if lower.contains("-----begin ") && lower.contains("private key-----") {
    self.private_key = true
    return Some("[credential output redacted]")
  }
  if self.private_key {
    if lower.contains("-----end ") && lower.contains("private key-----") {
      self.private_key = false
    }
    return None
  }
  let mut safe = text
  for secret in self.secrets {
    safe = safe.replace_all(old=secret, new="[redacted]")
  }
  // Free-text credential fields and URLs are not reliably delimited. Omit
  // their whole line rather than risk showing an unmatched value or suffix.
  let lower = safe.to_lower()
  if [
      "authorization", "cookie", "credential", "private_key", "private-key", "password",
      "passwd", "access_token", "refresh_token", "id_token", "api_key", "api-key",
      "apikey", "secret", "token", "bearer ", "basic ", "ghp_", "github_pat_", "age-secret-key-",
      "eyj",
    ]
    .iter()
    .any(marker => lower.contains(marker)) {
    return Some("[credential output redacted]")
  }
  if credential_prefix(lower, "sk-") {
    return Some("[credential output redacted]")
  }
  for word in safe.split(" ") {
    if word.contains("://") &&
      (word.contains("@") || word.contains("?") || word.contains("#")) {
      return Some("[credential URL redacted]")
    }
  }
  if safe.length() > 1024 {
    safe = safe[:1024].to_owned() + "… [truncated]"
  }
  Some(safe)
}

///|
async fn Progress::status(self : Progress, event : Json) -> Unit {
  guard field(event, "phase") is Some(Json::String(phase)) &&
    phase_label(phase) is Some(label) &&
    field(event, "state") is Some(Json::String(state)) &&
    ["started", "succeeded", "failed", "skipped"].contains(state) else {
    return
  }
  if self.phase_count < 128 {
    self.phase_count += 1
    save_diagnostic(
      self.stage,
      state,
      phase~,
      error_type?=if state == "failed" { Some("backend_phase") } else { None },
    )
  } else if self.phase_count == 128 {
    self.phase_count += 1
    save_diagnostic(
      self.stage,
      "diagnostics-truncated",
      error_type="phase_limit",
    )
  }
  let key = ["pipeline", "operationId", "phase", "step"]
    .map(name => field(event, name).unwrap_or(Json::null()).stringify())
    .join(":")
  if state == "started" {
    if self.operations.length() >= 256 {
      self.operations.clear()
    }
    self.operations.set(key, @env.now())
    progress_message(label + ": running…")
  } else {
    let duration = match field(event, "durationMs") {
      Some(Json::Number(value, ..)) if value >= 0 && value < 864000000 =>
        Some(seconds(value.to_uint64()))
      _ => self.operations.get(key).map(start => seconds(@env.now() - start))
    }
    self.operations.remove(key)
    let timing = duration.map(value => value + ", ").unwrap_or("") +
      "elapsed " +
      seconds(@env.now() - progress_started)
    progress_message(
      label +
      ": " +
      (if state == "succeeded" { "done" } else { state }) +
      " (" +
      timing +
      ")",
    )
  }
}

///|
fn classic_build_step(text : String) -> Bool {
  guard text.has_prefix("Step ") &&
    text[5:].split_once("/") is Some((step, rest)) &&
    rest.split_once(" ") is Some((total, detail)) else {
    return false
  }
  step.length() > 0 &&
  total.length() > 0 &&
  step.iter().all(c => c >= '0' && c <= '9') &&
  total.iter().all(c => c >= '0' && c <= '9') &&
  detail.trim().has_prefix(":")
}

///|
async fn Progress::message(
  self : Progress,
  text : String,
  debug~ : Bool,
  warning~ : Bool,
) -> Unit {
  for line in text.split("\n") {
    let text = line.trim().to_owned()
    if text == "" {
      continue
    }
    guard self.safe_message(text) is Some(safe) else { continue }
    if safe.has_prefix("#") {
      guard safe.split_once(" ") is Some((id, rest)) &&
        id.length() > 1 &&
        id[1:].iter().all(c => c >= '0' && c <= '9') else {
        continue
      }
      let detail = rest.trim().to_owned()
      guard detail.has_prefix("[") ||
        detail.has_prefix("DONE") ||
        detail.has_prefix("CACHED") else {
        continue
      }
      if self.builds.get(id.to_owned()) == Some(detail) {
        continue
      }
      if self.builds.length() < 2048 || self.builds.contains(id.to_owned()) {
        self.builds.set(id.to_owned(), detail)
      }
      progress_message("Build " + id.to_owned() + ": " + detail)
    } else if classic_build_step(safe) {
      // Classic RUN output has no prefix. Only its own completion marker
      // ends this mode; phase events on another pipe can arrive ahead of it.
      self.classic_build = true
      progress_message("Build " + safe)
    } else if safe.has_prefix("Successfully built ") ||
      safe.has_prefix("Successfully tagged ") {
      self.classic_build = false
      progress_message("Build: " + safe)
    } else if self.classic_build && !warning {
      continue
    } else if !debug && !safe.has_prefix("{") && !safe.has_prefix("[") {
      progress_message(self.stage + ": " + safe)
    } else if !debug && safe.has_prefix("[credential") {
      progress_message(self.stage + ": " + safe)
    }
  }
}

///|
async fn Progress::line(
  self : Progress,
  line : String,
  statuses~ : Bool,
  messages~ : Bool,
) -> Unit {
  if line.trim() == "" {
    return
  }
  let event = @json.parse(line) catch { _ => Json::null() }
  if field(event, "kind") == Some(Json::string("status")) {
    if statuses || messages {
      self.status(event)
    }
    return
  }
  let kind = field(event, "kind")
  if !messages &&
    !(statuses &&
    (kind == Some(Json::string("log")) || kind == Some(Json::string("error")))) {
    return
  }
  // Result envelopes and arbitrary structured responses are never log text.
  if field(event, "kind") == Some(Json::string("result")) {
    return
  }
  if event is Json::Object(_) {
    let kind = field(event, "kind")
    guard kind == None ||
      kind == Some(Json::string("log")) ||
      kind == Some(Json::string("error")) else {
      return
    }
    let message = match field(event, "msg") {
      Some(value) => Some(value)
      None => field(event, "message")
    }
    guard message is Some(Json::String(text)) else { return }
    let level = field(event, "level")
    self.message(
      text,
      debug=level == Some(Json::string("debug")) ||
        level == Some(Json::string("trace")),
      warning=kind == Some(Json::string("error")) ||
        level == Some(Json::string("warn")) ||
        level == Some(Json::string("error")),
    )
  } else {
    if event != Json::null() {
      return
    }
    // Malformed JSON and binary output are not a safe free-text fallback.
    let text = line.trim().to_owned()
    if text.has_prefix("{") || text.has_prefix("[") {
      return
    }
    self.message(
      text,
      debug=text.contains(" DEBUG ") ||
        text.contains(" TRACE ") ||
        text.has_prefix("DEBUG ") ||
        text.has_prefix("TRACE "),
      warning=text.contains(" WARN ") ||
        text.contains(" ERROR ") ||
        text.has_prefix("WARN ") ||
        text.has_prefix("ERROR "),
    )
  }
}

///|
async fn Progress::read_output(
  self : Progress,
  reader : @process.ReadFromProcess,
  capture~ : Bool,
  statuses~ : Bool = false,
  messages~ : Bool = false,
) -> String {
  let output = @buffer.Buffer(size_hint=4096)
  let pending = @buffer.Buffer(size_hint=4096)
  let mut oversized = false
  let mut tail = ""
  while reader.read_some(max_len=4096) is Some(chunk) {
    if capture {
      output.write_bytes(chunk)
    } else {
      tail += @utf8.decode_lossy(chunk)
      if tail.length() > 8192 {
        tail = tail[tail.length() - 8192:].to_owned()
      }
    }
    if !statuses && !messages {
      continue
    }
    for byte in chunk {
      if byte == b'\n' || byte == b'\r' {
        if !oversized && pending.length() > 0 {
          let line = @utf8.decode(pending.to_bytes()) catch { _ => "" }
          self.line(line, statuses~, messages~)
        }
        pending.reset()
        oversized = false
      } else if !oversized {
        if pending.length() == 65536 {
          pending.reset()
          oversized = true
        } else {
          pending.write_byte(byte)
        }
      }
    }
  }
  if !oversized && pending.length() > 0 {
    let line = @utf8.decode(pending.to_bytes()) catch { _ => "" }
    self.line(line, statuses~, messages~)
  }
  if capture {
    @utf8.decode(output.to_bytes())
  } else {
    tail
  }
}
