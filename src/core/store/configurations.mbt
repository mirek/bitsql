///|
/// Instance settings reside in master so configured values participate in
/// the same multi-database transactions and request snapshots as other data.
pub fn Db::configuration(self : Db, id : Int) -> (Int, Int)? {
  self.configurations.get(id)
}

///|
pub fn Db::set_configuration(
  self : Db,
  id : Int,
  configured : Int,
  active : Int,
) -> Db {
  { ..self, configurations: self.configurations.add(id, (configured, active)), }
}
