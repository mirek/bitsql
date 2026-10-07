///|
priv suberror OutboundHttp {
  OutboundHttp(String)
}

///|
/// Use the library for TCP/TLS, with an exact captured HTTP request. Its
/// higher-level client unconditionally adds Accept-Encoding, which SQL
/// Server's embedding requests do not send.
async fn http_attempt(
  request : @types.HttpRequest,
  trust : @tls.TrustedRoot,
) -> @types.HttpResult {
  guard request.url.has_prefix("https://") &&
    !request.url.contains("\r") &&
    !request.url.contains("\n") &&
    !request.url.contains("#") else {
    raise OutboundHttp("malformed HTTP response or URL")
  }
  let rest = request.url[8:].to_owned()
  let cut = rest.find_by(c => c == '/' || c == '?').unwrap_or(rest.length())
  let authority = rest[:cut].to_owned()
  let path = if cut == rest.length() {
    "/"
  } else {
    let tail = rest[cut:].to_owned()
    if tail.has_prefix("?") {
      "/" + tail
    } else {
      tail
    }
  }
  let client = @http.Client("https://" + authority, trust~)
  defer client.close()
  client.enter_passthrough_mode()
  let body = @utf8.encode(request.body)
  let headers = StringBuilder()
  headers.write_string("POST \{path} HTTP/1.1\r\n")
  for (key, value) in request.headers {
    headers.write_string("\{key}: \{value}\r\n")
  }
  headers.write_string(
    "Content-Length: \{body.length()}\r\nHost: \{authority}\r\n\r\n",
  )
  client.write(headers.to_string())
  client.write(body)
  client.flush()
  while true {
    guard client.read_until("\r\n") is Some(status_line) else {
      raise OutboundHttp("malformed HTTP response or URL")
    }
    let parts = status_line.split(" ").collect()
    guard parts.length() >= 2 else {
      raise OutboundHttp("malformed HTTP response or URL")
    }
    let status = @string.parse_int(parts[1])
    let response_headers : Map[String, String] = Map([])
    while true {
      guard client.read_until("\r\n") is Some(line) else {
        raise OutboundHttp("malformed HTTP response or URL")
      }
      if line == "" {
        break
      }
      guard line.split_once(":") is Some((key, value)) else {
        raise OutboundHttp("malformed HTTP response or URL")
      }
      response_headers[key.to_owned().to_lower()] = value.trim().to_owned()
    }
    if status >= 100 && status < 200 {
      continue
    }
    if response_headers.get("content-encoding") is Some(encoding) &&
      encoding != "identity" {
      raise OutboundHttp("HTTP content encoding \{encoding}")
    }
    let bytes = if status == 204 || status == 304 {
      b""
    } else if response_headers.get("transfer-encoding") is Some(encoding) {
      if encoding.to_lower() != "chunked" {
        raise OutboundHttp("malformed HTTP response or URL")
      }
      let out = @buffer.Buffer()
      while true {
        guard client.read_until("\r\n") is Some(line) else {
          raise OutboundHttp("malformed HTTP response or URL")
        }
        let n = @string.parse_int(line.split(";").next().unwrap_or(""), base=16)
        if n < 0 {
          raise OutboundHttp("malformed HTTP response or URL")
        }
        if n == 0 {
          while true {
            guard client.read_until("\r\n") is Some(trailer) else {
              raise OutboundHttp("malformed HTTP response or URL")
            }
            if trailer == "" {
              break
            }
          }
          break
        }
        out.write_bytes(client.read_exactly(n))
        if client.read_exactly(2) != b"\r\n" {
          raise OutboundHttp("malformed HTTP response or URL")
        }
      }
      out.to_bytes()
    } else if response_headers.get("content-length") is Some(length) {
      let n = @string.parse_int(length)
      if n < 0 {
        raise OutboundHttp("malformed HTTP response or URL")
      }
      client.read_exactly(n)
    } else {
      client.read_all().binary()
    }
    return HttpResponse(status, @utf8.decode(bytes))
  }
  abort("unreachable HTTP parser")
}

///|
async fn perform_http(
  request : @types.HttpRequest,
  trust : @tls.TrustedRoot,
) -> @types.HttpResult {
  try {
    for attempt = 0; ; attempt = attempt + 1 {
      let result = http_attempt(request, trust)
      if result is HttpResponse(status, _) &&
        attempt < request.retry_count &&
        request.retry_statuses.contains(status) {
        continue
      }
      return result
    }
  } catch {
    e => HttpFailure(e.to_string())
  }
}
