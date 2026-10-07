///|
fn external_option_error(name : String, state : Int) -> @types.SqlError {
  @types.sql_error(
    46504,
    "External option '\{name}' is not valid.  Ensure that the length and range are appropriate.",
    state~,
  )
}

///|
fn Session::exec_external_model(
  self : Session,
  mode : @ast.CreateMode,
  name : @ast.Ident,
  owner : @ast.Ident?,
  options : Array[@ast.OptionKV],
) -> Unit raise {
  let opts : Map[String, String] = Map([])
  for o in options {
    if o.value is Some(v) {
      opts[o.name] = v
    }
  }
  let db = self.db_of(0)
  let old = db.external_model(name.name)
  for
    (k, limit, state) in [
      ("LOCATION", 4000, 31),
      ("MODEL", 100, 32),
      ("API_FORMAT", 100, 34),
      ("PARAMETERS", 4000, 36),
      ("LOCAL_RUNTIME_PATH", 4000, 43),
    ] {
    if opts.get(k) is Some(v) && (v.is_empty() || v.length() > limit) {
      raise external_option_error(
        if k == "LOCAL_RUNTIME_PATH" {
          "PARAMETERS"
        } else {
          k
        },
        state,
      )
    }
  }
  let api = match opts.get("API_FORMAT") {
    None => old.map(m => m.api_format).unwrap_or("")
    Some(v) => {
      let trimmed = v.trim_end(chars=" ").to_owned()
      let canonical = match trimmed.to_upper() {
        "OPENAI" => "OpenAI"
        "AZURE OPENAI" => "Azure OpenAI"
        "OLLAMA" => "Ollama"
        "ONNX RUNTIME" => "ONNX Runtime"
        _ => {
          self.error_line = Some(16)
          raise @types.sql_error(
            46508,
            "Incorrect syntax on external DDL option 'API_FORMAT'.",
            severity=15,
            state=if mode is Alter { 34 } else { 32 },
          )
        }
      }
      canonical + "\u0000".repeat(v.length() - trimmed.length())
    }
  }
  let parameters = match opts.get("PARAMETERS") {
    None => old.bind(m => m.parameters)
    Some(v) =>
      Some(
        @types.JsonData::parse(v) catch {
          _ =>
            raise @types.sql_error(
              46557, "Argument 'PARAMETERS' is invalid. Please provide a valid Json document.",
            )
        },
      )
  }
  if mode is Create {
    for
      (k, state) in [
        ("LOCATION", 60),
        ("API_FORMAT", 61),
        ("MODEL", 62),
        ("MODEL_TYPE", 63),
      ] {
      if opts.get(k) is None {
        raise @types.sql_error(
          46505,
          "Missing required external DDL option '\{k}'.",
          state~,
        )
      }
    }
  } else if options.is_empty() {
    raise @types.sql_error(
      46505,
      "Missing required external DDL option 'SET_PARAMETER'.",
      state=43,
    )
  }
  if mode is Alter && old is None {
    self.cur_cmd = 170
    raise @types.sql_error(
      15151,
      "Cannot alter the object '\{name.name}', because it does not exist or you do not have permission.",
      state=203,
    )
  }
  if opts.get("CREDENTIAL") is Some(_) {
    raise @types.sql_error(
      46516,
      "The specified credential cannot be found or the user does not have permission to perform this action.",
      state=26,
    )
  }
  if owner is Some(o) &&
    !["dbo", "guest", "db_owner"].contains(o.name.to_lower()) {
    raise @types.sql_error(
      46555,
      "CREATE EXTERNAL MODEL failed because the user \"\{o.name}\" specified in the authorization clause does not exist.",
      state=3,
    )
  }
  let id = if mode is Create {
    let key = self.rt.database.to_lower()
    let id = self.server.external_model_ids.get(key).unwrap_or(65536)
    self.server.external_model_ids[key] = id + 1
    if old is Some(_) {
      raise @types.sql_error(
        46502,
        "Type with name '\{name.name}' already exists.",
        state=2,
      )
    }
    id
  } else {
    old.unwrap().id
  }
  let created = old.map(m => m.created).unwrap_or(self.rt.now)
  let modified = if old is Some(m) && self.rt.now <= m.modified {
    m.modified + 1L
  } else {
    self.rt.now
  }
  let m : @store.ExternalModel = {
    id,
    name: old.map(m => m.name).unwrap_or(name.name),
    principal_id: owner
    .map(o => {
      if o.name.to_lower() == "guest" {
        2
      } else if o.name.to_lower() == "db_owner" {
        16384
      } else {
        1
      }
    })
    .unwrap_or(old.map(m => m.principal_id).unwrap_or(1)),
    location: opts
    .get("LOCATION")
    .unwrap_or(old.map(m => m.location).unwrap_or("")),
    api_format: api,
    model: opts.get("MODEL").unwrap_or(old.map(m => m.model).unwrap_or("")),
    credential_id: None,
    parameters,
    local_runtime_path: match opts.get("LOCAL_RUNTIME_PATH") {
      Some(p) => Some(p)
      None => old.bind(m => m.local_runtime_path)
    },
    created,
    modified,
  }
  self.write(0, db.put_external_model(m))
  self.rt.rowcount = 0
  self.schema_ddl = true
}

///|
fn Session::exec_drop_external_model(
  self : Session,
  name : @ast.Ident,
) -> Unit raise {
  self.cur_cmd = 170
  let db = self.db_of(0)
  if db.external_model(name.name) is None {
    raise @types.sql_error(
      15151,
      "Cannot drop the object '\{name.name}', because it does not exist or you do not have permission.",
      state=202,
    )
  }
  self.write(0, db.drop_external_model(name.name))
  self.rt.rowcount = 0
  self.cur_cmd = 253
  self.schema_ddl = true
}
