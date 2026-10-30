///|
fn credential_field(name : String) -> Bool {
  let name = name
    .trim_start(chars="-")
    .to_owned()
    .to_lower()
    .replace_all(old="-", new="_")
  [
    "auth", "authorization", "proxy_authorization", "cookie", "set_cookie", "password",
    "passwd", "token", "access_token", "accesstoken", "refresh_token", "refreshtoken",
    "id_token", "api_key", "apikey", "x_api_key", "credential", "credentials", "secret",
    "client_secret", "clientsecret", "private_key", "privatekey", "aws_secret_access_key",
    "azure_storage_key", "docker_auth_config", "signature", "sig", "x_amz_signature",
    "x_amz_security_token", "x_goog_signature",
  ].contains(name) ||
  [
    "_auth", "_password", "_passwd", "_token", "_secret", "_api_key", "_private_key",
  ]
  .iter()
  .any(suffix => name.has_suffix(suffix))
}

///|
fn credential_word(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') ||
  (c >= 'A' && c <= 'Z') ||
  (c >= '0' && c <= '9') ||
  c == '_' ||
  c == '-'
}

///|
fn credential_space(c : Char) -> Bool {
  c == ' ' || c == '\t'
}

///|
fn credential_end(c : Char) -> Bool {
  credential_space(c) ||
  [',', ';', '&', '#', '"', '\'', '}', ']', '<', '>'].contains(c)
}

///|
fn character_text(chars : Array[Char], start : Int32, end : Int32) -> String {
  let buffer = @buffer.Buffer(size_hint=end - start)
  for i in start..<end {
    buffer.write_char_utf8(chars[i])
  }
  @utf8.decode_lossy(buffer.to_bytes())
}

///|
fn credential_hex(c : Char) -> Int32? {
  match c {
    '0'..<='9' => Some(c.to_int() - '0'.to_int())
    'a'..<='f' => Some(c.to_int() - 'a'.to_int() + 10)
    'A'..<='F' => Some(c.to_int() - 'A'.to_int() + 10)
    _ => None
  }
}

///|
fn credential_parameter(name : String) -> String {
  let chars = name.iter().to_array()
  let buffer = @buffer.Buffer(size_hint=name.length())
  let mut i = 0
  while i < chars.length() {
    if chars[i] == '%' &&
      i + 2 < chars.length() &&
      credential_hex(chars[i + 1]) is Some(hi) &&
      credential_hex(chars[i + 2]) is Some(lo) {
      buffer.write_char_utf8((hi * 16 + lo).unsafe_to_char())
      i += 3
    } else {
      buffer.write_char_utf8(chars[i])
      i += 1
    }
  }
  @utf8.decode_lossy(buffer.to_bytes())
}

///|
fn redact_credentials(text : String) -> String {
  let chars = text.iter().to_array()
  let buffer = @buffer.Buffer(size_hint=text.length())
  let mut i = 0
  let mut url = false
  while i < chars.length() {
    if credential_space(chars[i]) || ['"', '\''].contains(chars[i]) {
      url = false
    }
    if chars[i] == ':' &&
      i + 2 < chars.length() &&
      chars[i + 1] == '/' &&
      chars[i + 2] == '/' {
      url = true
      buffer.write_string_utf8("://")
      i += 3
      let mut end = i
      let mut user_end = None
      while end < chars.length() &&
            !credential_end(chars[end]) &&
            !['/', '?'].contains(chars[end]) {
        if chars[end] == '@' {
          user_end = Some(end)
        }
        end += 1
      }
      if user_end is Some(end) {
        buffer.write_string_utf8("[redacted]@")
        i = end + 1
      }
      continue
    }
    if url && ['?', '&'].contains(chars[i]) {
      let start = i
      i += 1
      while i < chars.length() && !credential_end(chars[i]) && chars[i] != '=' {
        i += 1
      }
      let name = credential_parameter(character_text(chars, start + 1, i))
      if i < chars.length() && chars[i] == '=' {
        i += 1
        buffer.write_string_utf8(character_text(chars, start, i))
        if credential_field(name) || name.to_lower() == "key" {
          while i < chars.length() && !credential_end(chars[i]) {
            i += 1
          }
          buffer.write_string_utf8("[redacted]")
          if i < chars.length() &&
            chars[i] == ']' &&
            i >= 9 &&
            character_text(chars, i - 9, i + 1) == "[redacted]" {
            i += 1
          }
        }
      } else {
        buffer.write_string_utf8(character_text(chars, start, i))
      }
      continue
    }
    if credential_word(chars[i]) && (i == 0 || !credential_word(chars[i - 1])) {
      let start = i
      let mut end = i
      while end < chars.length() && credential_word(chars[end]) {
        end += 1
      }
      let word = character_text(chars, start, end)
      let lower = word.to_lower()
      if [
          "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_", "sk-", "age-secret-key-",
        ]
        .iter()
        .any(prefix => lower.has_prefix(prefix)) ||
        (word.has_prefix("eyJ") && end < chars.length() && chars[end] == '.') {
        while end < chars.length() && !credential_end(chars[end]) {
          end += 1
        }
        buffer.write_string_utf8("[redacted]")
        i = end
        continue
      }
      let mut separator = end
      if separator < chars.length() && ['"', '\''].contains(chars[separator]) {
        separator += 1
      }
      while separator < chars.length() && credential_space(chars[separator]) {
        separator += 1
      }
      let mut previous = start
      while previous > 0 && credential_space(chars[previous - 1]) {
        previous -= 1
      }
      let field_start = previous == 0 ||
        [';', ',', '{', '"', '\'', '?', '&'].contains(chars[previous - 1])
      let option = word.has_prefix("--")
      let prose_credential = ["credential", "credentials"].contains(lower) &&
        !field_start
      let assignment = separator < chars.length() &&
        (
          chars[separator] == '=' ||
          (chars[separator] == ':' && !prose_credential)
        )
      if credential_field(word) && (assignment || (option && separator > end)) {
        let mut value = if assignment { separator + 1 } else { separator }
        while value < chars.length() && credential_space(chars[value]) {
          value += 1
        }
        buffer.write_string_utf8(character_text(chars, start, value))
        let quoted_key = start > 0 &&
          end < chars.length() &&
          ['"', '\''].contains(chars[start - 1]) &&
          chars[start - 1] == chars[end]
        if ["cookie", "set-cookie", "--cookie"].contains(lower) && !quoted_key {
          buffer.write_string_utf8("[redacted]")
          i = chars.length()
        } else if value + 10 <= chars.length() &&
          character_text(chars, value, value + 10) == "[redacted]" {
          buffer.write_string_utf8("[redacted]")
          i = value + 10
        } else if value < chars.length() && ['"', '\''].contains(chars[value]) {
          let quote = chars[value]
          buffer.write_char_utf8(quote)
          value += 1
          while value < chars.length() && chars[value] != quote {
            if chars[value] == '\\' && value + 1 < chars.length() {
              value += 1
            }
            value += 1
          }
          buffer.write_string_utf8("[redacted]")
          i = value
        } else {
          let mut value_end = value
          while value_end < chars.length() && !credential_end(chars[value_end]) {
            value_end += 1
          }
          let scheme = character_text(chars, value, value_end).to_lower()
          if scheme == "bearer" || scheme == "basic" {
            while value_end < chars.length() &&
                  credential_space(chars[value_end]) {
              value_end += 1
            }
            buffer.write_string_utf8(character_text(chars, value, value_end))
            value = value_end
            while value_end < chars.length() &&
                  !credential_end(chars[value_end]) {
              value_end += 1
            }
          }
          if value + 10 <= chars.length() &&
            character_text(chars, value, value + 10) == "[redacted]" {
            value_end = value + 10
          }
          if value_end > value {
            buffer.write_string_utf8("[redacted]")
          }
          i = value_end
        }
        continue
      }
      buffer.write_string_utf8(word)
      i = end
      continue
    }
    buffer.write_char_utf8(chars[i])
    i += 1
  }
  @utf8.decode_lossy(buffer.to_bytes())
}

///|
fn Progress::safe_message(self : Progress, text : String) -> String? {
  guard terminal_text(text) is Some(text) else { return None }
  let lower = text.to_lower()
  if lower.contains("-----begin ") && lower.contains("private key-----") {
    self.private_key = !lower.contains("-----end ")
    return Some("[private key redacted]")
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
  safe = redact_workspace_info_argument(safe)
  safe = redact_credentials(safe)
  if safe.length() > 1024 {
    safe = safe[:1024].to_owned() + "… [truncated]"
    self.details_truncated = true
  }
  Some(safe)
}

///|
fn redact_workspace_info_argument(text : String) -> String {
  match text.split_once("--workspace-info ") {
    Some((prefix, argument_and_suffix)) =>
      prefix.to_owned() +
      "--workspace-info [redacted]" +
      redact_workspace_info_argument_suffix(argument_and_suffix.to_owned())
    None => text
  }
}

///|
fn redact_workspace_info_argument_suffix(text : String) -> String {
  if text.has_prefix("\"") {
    let chars = text.iter().to_array()
    let mut i = 1
    let mut escaped = false
    while i < chars.length() {
      if chars[i] == '"' && !escaped {
        return redact_workspace_info_argument(
          character_text(chars, i + 1, chars.length()),
        )
      }
      if chars[i] == '\\' {
        escaped = !escaped
      } else {
        escaped = false
      }
      i += 1
    }
    ""
  } else {
    match text.split_once(" ") {
      Some((_, suffix)) =>
        " " + redact_workspace_info_argument(suffix.to_owned())
      None => ""
    }
  }
}
