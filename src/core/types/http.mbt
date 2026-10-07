///|
/// Pure HTTP effect description. The host performs transport and retries;
/// the engine records the completed response for deterministic replay.
pub(all) struct HttpRequest {
  url : String
  body : String
  headers : Array[(String, String)]
  retry_count : Int
  retry_statuses : Array[Int]
} derive(Debug, Eq)

///|
pub(all) enum HttpResult {
  HttpResponse(Int, String)
  HttpFailure(String)
} derive(Debug, Eq)
