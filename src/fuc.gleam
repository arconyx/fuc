import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import gleam/string_tree
import gleam/uri

import envoy
import mist
import wisp.{type Request, type Response}
import wisp/wisp_mist

type OAuthClient {
  OAuthClient(id: String, secret: String)
}

/// Context for server invocation
/// `oauth_client` supplies the id and secret for Google OAuth
/// `address` is the public facing address for the site, including protocol
/// and port and subfolder (if necessary)
/// e.g. https://thehivemind.gay:3000/fuq
/// Use the public facing domain and port as exposed by your reverse proxy
/// `port` this process should listen on. May differ from the port included in the address
type Context {
  Context(oauth_client: OAuthClient, address: String, port: Int)
}

pub fn main() {
  wisp.configure_logger()

  // TODO: Store state on server so it is used across invocations
  let secret_key_base = wisp.random_string(64)
  let ctx = load_environment()

  let server =
    result.map(ctx, fn(ctx) {
      route_request(_, ctx)
      |> wisp_mist.handler(secret_key_base)
      |> mist.new()
      |> mist.bind("localhost")
      |> mist.port(8000)
      |> mist.start()
    })

  case server {
    Ok(_) -> process.sleep_forever()
    Error(e) -> {
      wisp.log_critical("Unable to start server")
      echo e
      Nil
    }
  }
}

type ContextError {
  MissingVariable(key: String)
  ParsingError(value: String)
  Impossible(wtf: String)
}

/// Wrap envoy.get() with a more helpful error
fn get_env_var(name: String) -> Result(String, ContextError) {
  case envoy.get(name) {
    Ok("") -> Error(MissingVariable(name))
    Ok(val) -> Ok(val)
    Error(_) -> Error(MissingVariable(name))
  }
}

/// Init context, loading information from environment variables
fn load_environment() -> Result(Context, ContextError) {
  use id <- result.try(get_env_var("FUC_OAUTH_CLIENT_ID"))
  use secret <- result.try(get_env_var("FUC_OAUTH_CLIENT_SECRET"))
  let client = OAuthClient(id, secret)

  use port_str <- result.try(get_env_var("FUC_PORT"))
  let port = case int.parse(port_str) {
    Ok(i) -> Ok(i)
    Error(_) -> Error(ParsingError("Cannot parse port '" <> port_str <> "'"))
  }
  use port <- result.try(port)

  // Get address, dropping any trailing /
  use addr <- result.try(get_env_var("FUC_ADDRESS"))
  let addr = case string.last(addr) {
    Ok("/") -> Ok(string.drop_end(addr, 1))
    Ok(_) -> Ok(addr)
    Error(_) ->
      Error(Impossible(
        "Address is empty despite get_env_var validating it isn't",
      ))
  }
  use addr <- result.try(addr)

  Context(client, addr, port) |> Ok
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
fn route_request(req: Request, ctx: Context) -> Response {
  use req <- gracefully_wrap_requests(req)

  case wisp.path_segments(req) {
    // matches `/`
    [] -> home_page(req, ctx)
    ["login"] -> login_page(req, ctx)
    ["auth", "google"] -> start_google_login(req, ctx)
    ["auth", "callback"] -> google_auth_callback(req, ctx)
    _ -> wisp.not_found()
  }
}

// Handle GET requests to `/`
// Other methods will error
fn home_page(req: Request, _ctx: Context) -> Response {
  use <- wisp.require_method(req, http.Get)

  let body = string_tree.from_string("<p>Hello World</p>")

  wisp.ok()
  |> wisp.html_body(body)
}

type OAuthRequest {
  OAuthRequest(url: String, state: String)
}

/// Landing page to prompt for user auth
/// Handles GET only
fn login_page(req: Request, _ctx: Context) -> Response {
  use <- wisp.require_method(req, http.Get)

  let body =
    string_tree.from_string("<a href='/auth/google'>Login with Google</a>")

  wisp.ok()
  |> wisp.html_body(body)
}

/// Redirect to Google's OAuth login page
/// Accepts GET only
fn start_google_login(req: Request, ctx: Context) -> Response {
  use <- wisp.require_method(req, http.Get)
  let auth_request = construct_oauth_request(ctx)

  // This uses a 303 redirect, which appears to be what is recommended for openid
  // https://openid.net/specs/openid-connect-core-1_0.html#HTTP307Redirects
  wisp.redirect(auth_request.url)
  // I've checked the wisp source.
  // It uses the gleam/http/cookie defaults which include HttpOnly = true and SameSite = Lax
  // which seems about what we want.
  // Five minute timeout is trying to strike a balance between not lingering and
  // not expiring if the user takes a while to login
  |> wisp.set_cookie(
    req,
    "oauth_state",
    auth_request.state,
    wisp.Signed,
    5 * 60,
  )
}

/// Returns the percent encoded URL used for OAuth redirect
fn construct_callback_url(ctx: Context) -> String {
  let full_address = ctx.address <> "/auth/callback"
  uri.percent_encode(full_address)
}

fn construct_oauth_request(ctx: Context) -> OAuthRequest {
  // TODO: Split the state into client and server properties
  // Record the server value in the database and invalidate it after use
  // Wait, is there any point? It has to be passed to the client in the request
  // Ah, we can use the hash in the request
  let state = wisp.random_string(128)
  let url =
    "https://accounts.google.com/o/oauth2/v2/auth?"
    <> "client_id="
    <> ctx.oauth_client.id
    <> "&redirect_uri="
    <> construct_callback_url(ctx)
    <> "&response_type=code"
    // Scopes are a space seperated list
    // Requested scopes: gmail.labels
    <> "&scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fgmail.labels"
    <> "&access_type=online"
    <> "&state="
    <> state
    <> "&nonce="
    <> wisp.random_string(64)

  OAuthRequest(url, state)
}

/// Middleware that asserts that the request has valid oauth state
fn validate_state(req: Request, next: fn() -> Response) -> Response {
  let query = wisp.get_query(req)
  // Validate the state token matches the signed value on the client
  // TODO: Expire state cookie
  let state = {
    use remote <- result.try(list.key_find(query, "state"))
    use client <- result.try(wisp.get_cookie(req, "oauth_state", wisp.Signed))
    case client == remote {
      True -> Ok(True)
      False -> Error(Nil)
    }
  }

  case state {
    Ok(_) -> next()
    Error(_) -> {
      wisp.log_warning("State validation failed")
      wisp.bad_request()
    }
  }
}

type OAuthToken {
  // TODO: Record expiry times
  OAuthToken(access: String, refresh: String, token_type: String)
}

/// Exchange an authorization code for oauth tokens
fn request_token(req: Request, ctx: Context) -> Result(OAuthToken, Nil) {
  let query = wisp.get_query(req)
  use code <- result.try(list.key_find(query, "code"))

  let body =
    "client_id="
    <> ctx.oauth_client.id
    <> "&client_secret="
    <> ctx.oauth_client.secret
    <> "&code="
    <> code
    <> "&grant_type=authorization_code"
    // This needs to exactly match the earlier redirect uri
    // Google should validate that they match
    <> "&redirect_uri="
    <> construct_callback_url(ctx)
    <> "auth%2Fcallback"

  use token_req <- result.try(request.to("https://oauth2.googleapis.com/token"))
  let token_req =
    token_req
    |> request.set_method(http.Post)
    |> request.set_header("content-type", "application/x-www-form-urlencoded")
    |> request.prepend_header("accept", "application/json")
    |> request.set_body(body)

  // Send token request
  // Replace the error type if we fail
  let resp = case httpc.send(token_req) {
    Ok(r) -> Ok(r)
    Error(e) -> {
      case e {
        httpc.InvalidUtf8Response ->
          wisp.log_warning("Token request failed: invalid utf-8 data")
        httpc.FailedToConnect(_, _) ->
          wisp.log_warning("Token request failed: unable to connect to host")
        httpc.ResponseTimeout ->
          wisp.log_warning("Token request failed: timeout")
      }
      Error(Nil)
    }
  }

  use resp <- result.try(resp)
  let resp_body = case resp.status {
    200 -> Ok(resp.body)
    status -> {
      wisp.log_warning("Token request failed: status" <> int.to_string(status))
      Error(Nil)
    }
  }
  use resp_body <- result.try(resp_body)
  let decoder = {
    use access_token <- decode.field("access_token", decode.string)
    use refresh_token <- decode.field("refresh_token", decode.string)
    // Apparently always 'Bearer' atm
    use token_type <- decode.field("token_type", decode.string)
    // TODO: Parse expiry times
    // They're given in seconds from the current time so we'll have to calculate
    // the associated unix epoch
    decode.success(OAuthToken(access_token, refresh_token, token_type))
  }
  json.parse(resp_body, decoder)
  |> result.map_error(fn(_) {
    wisp.log_warning("Unable to decode access token")
    Nil
  })
}

fn google_auth_callback(req: Request, ctx: Context) -> Response {
  use <- wisp.require_method(req, http.Get)
  use <- validate_state(req)

  case request_token(req, ctx) {
    Ok(token) -> {
      wisp.log_info("Login successful")
      // FOR DEBUGGING ONLY
      wisp.log_info(token.access)
    }
    Error(_) -> wisp.log_warning("Login failed")
  }
  wisp.redirect("/")
}
