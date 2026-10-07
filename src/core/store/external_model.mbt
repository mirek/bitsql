///|
/// External models have a database-local namespace independent of objects.
/// Definitions are transactional; their ID allocator belongs to the server.
pub(all) struct ExternalModel {
  id : Int
  name : String
  principal_id : Int
  location : String
  api_format : String
  model : String
  credential_id : Int?
  parameters : @types.JsonData?
  local_runtime_path : String?
  created : Int64
  modified : Int64
}

///|
pub fn Db::external_models(self : Db) -> Array[ExternalModel] {
  self.external_models.iter().map(kv => kv.1).collect()
}

///|
pub fn Db::external_model(self : Db, name : String) -> ExternalModel? {
  self.external_models.get(name.to_lower())
}

///|
pub fn Db::put_external_model(self : Db, m : ExternalModel) -> Db {
  { ..self, external_models: self.external_models.add(m.name.to_lower(), m), }
}

///|
pub fn Db::drop_external_model(self : Db, name : String) -> Db {
  { ..self, external_models: self.external_models.remove(name.to_lower()), }
}
