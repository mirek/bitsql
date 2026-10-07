///|
/// Wire formats of SQL Server external embedding models. The caller resolves
/// the stored API_FORMAT before preparing or decoding an HTTP exchange.
pub(all) enum EmbeddingApi {
  OpenAI
  AzureOpenAI
  Ollama
} derive(Debug, Eq)

///|
pub(all) struct EmbeddingRequest {
  body : String
  retry_count : Int
} derive(Debug, Eq)

///|
fn embedding_parameters(
  doc : JsonData?,
  stage : Int,
) -> Array[(String, JsonStorageNode)] raise SqlError {
  guard doc is Some(doc) else { return [] }
  match json_storage_tree(doc.checked_text()) {
    NObject(fields, _) => fields
    _ =>
      raise sql_error(
        31732,
        "'\{if stage == 1 { "Model" } else { "Optional" }} Parameters' must be a valid JSON object.",
        state=if stage == 1 { 1 } else { 3 },
      )
  }
}

///|
/// Prepare the exact JSON payload separately from HTTP. Optional parameters
/// replace model parameters while retaining the existing key's position.
pub fn embedding_request(
  api : EmbeddingApi,
  model : String,
  source : String?,
  parameters : JsonData?,
  optional : JsonData?,
) -> EmbeddingRequest raise SqlError {
  guard source is Some(source) else {
    raise sql_error(
      31701, "Parameter 'input data' must be specified. This parameter cannot be NULL.",
    )
  }
  let fields : Array[(String, JsonStorageNode, Int)] = []
  for (doc, stage) in [(parameters, 1), (optional, 2)] {
    for (key, value) in embedding_parameters(doc, stage) {
      let mut replaced = false
      for i in 0..<fields.length() {
        if fields[i].0 == key {
          fields[i] = (key, value, stage)
          replaced = true
          break
        }
      }
      if !replaced {
        fields.push((key, value, stage))
      }
    }
  }
  let body = StringBuilder()
  body.write_string("{")
  if !(api is AzureOpenAI) {
    body.write_string("\"model\":")
    write_json_type_string(body, replace_lone_surrogates(model))
    body.write_string(",")
  }
  body.write_string("\"input\":" + @json.quote(replace_lone_surrogates(source)))
  let mut retry_count = 0
  for (key, value, stage) in fields {
    if key == "model" || key == "input" {
      raise sql_error(
        31731,
        "The provided JSON parameters (e.g., '\{key}') are not allowed.",
        state=stage,
      )
    }
    if key == "sql_rest_options" {
      guard value is NObject(options, _) else {
        // The captured string value kills only the SQL session. Transport
        // integration must preserve that disposition without crashing a host.
        if value is NScalar(_, text) && text.has_prefix("\"") {
          raise sql_error(
            596,
            "Cannot continue the execution because the session is in the kill state.",
            severity=21,
          )
        }
        raise not_supported("this sql_rest_options value")
      }
      for (option, v) in options {
        if option != "retry_count" {
          continue
        }
        let number = match v {
          NScalar(_, text) => Decimal::parse(text[:])
          _ => None
        }
        guard number is Some(n) && n.scale() == 0 else {
          raise sql_error(
            31735,
            "The JSON value for the JSON key 'retry_count' must be 'Integer' type.",
            state=stage,
          )
        }
        if n.coef().compare_int(0) < 0 || n.coef().compare_int(10) > 0 {
          raise sql_error(
            31734,
            "The value '\{n.coef()}' is not within range for the retry_count parameter.",
            state=stage,
          )
        }
        retry_count = n.coef().to_int()
      }
    } else {
      let text = value.to_text()
      let encoded = if text.has_prefix("\"") {
        let parser : JsonTypeParser = { b: utf8_bytes(text), pos: 0, }
        @json.quote(parser.string())
      } else {
        text
      }
      body.write_string("," + @json.quote(key) + ":" + encoded)
    }
  }
  body.write_string("}")
  { body: body.to_string(), retry_count, }
}

///|
/// Statuses SQL Server treats as retryable. With no retries remaining the
/// embedding result is NULL (captured, including an error JSON response).
pub fn embedding_retryable_status(status : Int) -> Bool {
  [408, 429, 500, 502, 503, 504].contains(status)
}

///|
/// Decode a completed embedding response after retry handling. This function
/// is pure: transport, timeouts, retries and cancellation belong to the host.
/// Captures: harness/fixtures/embeddings.expected.json.
pub fn embedding_response(
  api : EmbeddingApi,
  status : Int,
  body : String,
) -> Value raise SqlError {
  if embedding_retryable_status(status) {
    return Null
  }
  if status < 200 || status >= 300 {
    raise sql_error(
      31742,
      "Unrecoverable HTTP error \{status}  occured.",
      state=3,
    )
  }
  if status == 204 || body.is_empty() {
    raise sql_error(
      31718,
      "An internal error has occurred. Please retry the operation. If the issue persists, contact support for assistance.",
      state=21,
      severity=17,
    )
  }
  let valid = @json.isjson(body) catch { _ => 0 }
  if valid != 1 {
    raise sql_error(31745, "The HTTP response does not contain valid JSON.")
  }
  let path = match api {
    OpenAI | AzureOpenAI => "$.data[0].embedding"
    Ollama => "$.embeddings[0]"
  }
  let selected = @json.json_query(body, path~) catch {
    _ =>
      raise sql_error(31745, "The HTTP response does not contain valid JSON.")
  }
  guard selected is Some(text) else {
    raise sql_error(
      31744, "The JSON path for embeddings could not be found in the response.",
    )
  }
  // Conversion applies to the selected subtree, not the whole response.
  // A 1e300 outside the embedding is ignored; inside it raises 1007. The
  // selected value may be an object or a mixed array, not necessarily a vector.
  NativeJson(JsonData::parse(text))
}
