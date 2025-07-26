import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/result

pub fn main() {
  let req = request.to("https://test-api.service.hmrc.gov.uk/hello/world")

  let status = case req {
    Ok(r) -> {
      // Send the HTTP request to the server
      let resp = httpc.send(r)
      case resp {
        Ok(r) -> Ok(r.status)
        Error(_) -> Error("Request failed")
      }
    }
    Error(_) -> Error("Unable to form request")
  }
  result.map(status, fn(st) { echo st })
}

fn oauth_authorise() {
  todo
}
