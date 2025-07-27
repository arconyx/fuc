import gleam/erlang/process
import gleam/http
import gleam/string_tree

import mist
import wisp.{type Request, type Response}
import wisp/wisp_mist

pub fn main() {
  wisp.configure_logger()
  let secret_key_base = wisp.random_string(64)

  let server =
    route_request
    |> wisp_mist.handler(secret_key_base)
    |> mist.new()
    |> mist.bind("localhost")
    |> mist.port(8000)
    |> mist.start()

  case server {
    Ok(_) -> process.sleep_forever()
    Error(e) -> {
      wisp.log_critical("Unable to start server")
      echo e
      Nil
    }
  }
}

/// Middleware to wrap requests and implement some generic handling for them
fn gracefully_wrap_requests(
  req: wisp.Request,
  handle_request: fn(wisp.Request) -> wisp.Response,
) -> wisp.Response {
  let req = wisp.method_override(req)
  use <- wisp.log_request(req)
  use <- wisp.rescue_crashes
  use req <- wisp.handle_head(req)
  // Not released yet
  // use req <- wisp.csrf_known_header_protection(req)

  handle_request(req)
}

/// Route requests to a handler
fn route_request(req: Request) -> Response {
  use req <- gracefully_wrap_requests(req)

  case wisp.path_segments(req) {
    // matches `/`
    [] -> handle_root(req)
    _ -> wisp.not_found()
  }
}

fn handle_root(req: Request) -> Response {
  use <- wisp.require_method(req, http.Get)

  let body = string_tree.from_string("<p>Hello World</p>")

  wisp.ok()
  |> wisp.html_body(body)
}
