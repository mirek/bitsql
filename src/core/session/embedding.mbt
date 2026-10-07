///|
pub struct EmbeddingCall {
  inputs : Array[@types.Value]
  request : @types.HttpRequest
  api : @types.EmbeddingApi
  mut result : Result[@types.Value, @types.SqlError]?
}

///|
fn Session::prepare_embedding(
  self : Session,
  args : Array[@types.Value],
) -> EmbeddingCall raise @types.SqlError {
  if !self.rest_enabled() {
    raise @types.sql_error(
      31643,
      "'ai_generate_embeddings' is disabled on this instance of SQL Server. Use sp_configure 'external rest endpoint enabled' to enable it.",
      state=2,
    )
  }
  guard args[0] is String(name) else {
    raise @types.not_supported("embedding model expression")
  }
  guard self.db_of(0).external_model(name) is Some(model) else {
    raise @types.sql_error(
      15151,
      "Cannot find the external model '\{name}', because it does not exist or you do not have permission.",
      state=10,
    )
  }
  let api : @types.EmbeddingApi = match model.api_format {
    "OpenAI" => OpenAI
    "Azure OpenAI" => AzureOpenAI
    "Ollama" => Ollama
    other => raise @types.not_supported("embedding API format '\{other}'")
  }
  let source = match args[1] {
    String(s) => Some(s)
    _ => None
  }
  let optional = match args.get(2) {
    Some(NativeJson(j)) => Some(j)
    _ => None
  }
  let prepared = @types.embedding_request(
    api,
    model.model,
    source,
    model.parameters,
    optional,
  )
  let request : @types.HttpRequest = {
    url: model.location,
    body: prepared.body,
    retry_count: prepared.retry_count,
    retry_statuses: [408, 429, 500, 502, 503, 504],
    headers: [
      ("Connection", "Keep-Alive"),
      ("Content-Type", "application/json;charset=utf-8"),
      ("Accept", "application/json"),
      ("User-Agent", "Enterprise Developer Edition (64-bit)/17.0.5005.3"),
    ],
  }
  { inputs: args.copy(), request, api, result: None, }
}

///|
fn Session::embedding(
  self : Session,
  args : Array[@types.Value],
) -> @types.Value raise @types.SqlError {
  if self.attn.hit {
    return Null
  }
  let index = self.embeddings_seen
  self.embeddings_seen += 1
  let call = match self.embeddings.get(index) {
    Some(call) => {
      if call.inputs != args {
        raise @types.not_supported(
          "embedding input changed during request replay",
        )
      }
      call
    }
    None => {
      let call = self.prepare_embedding(args)
      self.embeddings.push(call)
      call
    }
  }
  match call.result {
    Some(Ok(value)) => value
    Some(Err(error)) => raise error
    None => {
      if self.attn.cancelling {
        self.attn.hit = true
        self.rt.cancel_pending = true
        return Null
      }
      self.embedding_pending = Some(index)
      raise @types.Suspend
    }
  }
}

///|
pub fn Session::pending_http(self : Session) -> @types.HttpRequest? {
  self.embedding_pending.map(i => self.embeddings[i].request)
}

///|
pub fn Session::complete_http(
  self : Session,
  response : @types.HttpResult,
) -> Unit {
  guard self.embedding_pending is Some(i) else { return }
  let call = self.embeddings[i]
  call.result = Some(
    try {
      match response {
        HttpResponse(status, body) =>
          Ok(@types.embedding_response(call.api, status, body))
        HttpFailure(reason) =>
          Err(
            @types.not_supported("embedding HTTP transport failure: \{reason}"),
          )
      }
    } catch {
      e => Err(e)
    },
  )
  self.embedding_pending = None
}
