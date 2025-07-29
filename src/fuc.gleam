import gleam/dynamic/decode
import gleam/erlang/process
import gleam/hackney
import gleam/http
import gleam/http/request
import gleam/int
import gleam/json
import gleam/list
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/string_tree
import gleam/uri
import sqlight

import envoy
import mist
import wisp.{type Request, type Response}
import wisp/wisp_mist

// ////////////// ENTRY POINT ///////////////

/// Entry point
/// Starts server
pub fn main() {
  wisp.configure_logger()

  let server = {
    use ctx <- result.try(load_context())
    // There is no need for the secret key to be in the context
    use secret_key_base <- result.try(get_env_var("FUC_SECRET_KEY"))

    route_request(_, ctx)
    |> wisp_mist.handler(secret_key_base)
    |> mist.new()
    |> mist.bind("localhost")
    |> mist.port(8000)
    |> mist.start()
    |> result.map_error(fn(e) { MistError(e) })
  }

  case server {
    Ok(_) -> process.sleep_forever()
    Error(e) -> {
      wisp.log_critical("Unable to start server")
      echo e
      Nil
    }
  }
}

// /////////////// SERVER CONFIGURATION & STARTUP ///////////////////////

/// Errors reported during context parsing and other parts of startup
type StartupError {
  MissingVariable(key: String)
  ParsingError(value: String)
  Impossible(wtf: String)
  DatabaseError(err: sqlight.Error)
  MistError(err: actor.StartError)
}

/// Context for server invocation
/// `oauth_client` supplies the id and secret for Google OAuth
/// `address` is the public facing address for the site, including protocol
/// and port and subfolder (if necessary)
/// e.g. https://thehivemind.gay:3000/fuq
/// Use the public facing domain and port as exposed by your reverse proxy
/// `port` this process should listen on. May differ from the port included in the address
/// `database_path` points to an sqlite3 database
type Context {
  Context(
    oauth_client: OAuthClient,
    address: String,
    port: Int,
    database_connection: sqlight.Connection,
  )
}

/// Basic abstraction for oauth client information
type OAuthClient {
  OAuthClient(id: String, secret: String)
}

/// Init context, loading information from environment variables
/// This calls create_database because it should be an error to have
/// a context with an invalid database referenced.
fn load_context() -> Result(Context, StartupError) {
  // OAuth information gets a special type
  // This is probably overkill tbh
  use id <- result.try(get_env_var("FUC_OAUTH_CLIENT_ID"))
  use secret <- result.try(get_env_var("FUC_OAUTH_CLIENT_SECRET"))
  let client = OAuthClient(id, secret)

  use port_str <- result.try(get_env_var("FUC_PORT"))
  let port = case int.parse(port_str) {
    Ok(i) -> Ok(i)
    Error(_) -> Error(ParsingError("Cannot parse port '" <> port_str <> "'"))
  }
  use port <- result.try(port)

  // We drop any trailing slashes from the address
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

  // Create the database as soon as we know what it is called
  use database_path <- result.try(get_env_var("FUC_DATABASE_PATH"))
  let conn =
    sqlight.open(database_path)
    |> result.map_error(fn(e) { DatabaseError(e) })
    |> result.try(create_database)
  use conn <- result.try(conn)

  Context(client, addr, port, conn) |> Ok
}

/// Get an environment variable
/// Wraps envoy.get() with a more helpful error
/// Empty environment variables are treated as an error
fn get_env_var(name: String) -> Result(String, StartupError) {
  case envoy.get(name) {
    Ok("") -> Error(MissingVariable(name))
    Ok(val) -> Ok(val)
    Error(_) -> Error(MissingVariable(name))
  }
}

// ////////////// DATABASE I/O ////////////////////////

/// Init database with tables
/// This must be idempotent because it may be
/// called on existing databases
fn create_database(
  conn: sqlight.Connection,
) -> Result(sqlight.Connection, StartupError) {
  let create =
    sqlight.exec(
      "CREATE TABLE IF NOT EXISTS google_oauth_tokens (
    id INTEGER PRIMARY KEY,
    access TEXT UNIQUE NOT NULL
  )",
      conn,
    )

  case create {
    Ok(Nil) -> Ok(conn)
    Error(e) -> Error(DatabaseError(e))
  }
}

// /////////// REQUEST HANDLING ///////////////

/// Middleware to wrap requests and implement some generic handling for them
/// - Method types are overriden if requested by caller
/// - Requests are logged
///  - Crashes return 500
///  - HEAD requests are redirected to GET
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

/// Method override allows changing message types when calling from the browser
/// (we shouldn't need this - I think it only matters for JS?)
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

// ////////// ENDPOINTS ////////////////////////

// Handle GET requests to the site root
fn home_page(req: Request, _ctx: Context) -> Response {
  use <- wisp.require_method(req, http.Get)

  let body = string_tree.from_string("<p>Hello World</p>")

  wisp.ok()
  |> wisp.html_body(body)
}

/// Landing page to prompt for user auth
fn login_page(req: Request, _ctx: Context) -> Response {
  use <- wisp.require_method(req, http.Get)

  let body =
    string_tree.from_string("<a href='/auth/google'>Login with Google</a>")

  wisp.ok()
  |> wisp.html_body(body)
}

// /////////// OAUTH HANDLING /////////////////

/// Redirect to Google's OAuth login page
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

/// Encapsulate oauth request metadata
/// The state needs to be in the url and stored seperately
type OAuthRequest {
  OAuthRequest(url: String, state: String)
}

/// Returns the percent encoded URL used for OAuth redirect
fn construct_callback_url(ctx: Context) -> String {
  let full_address = ctx.address <> "/auth/callback"
  uri.percent_encode(full_address)
}

/// Generate an OAuth request with random state and nonce
/// using the appropriate callback url for the server configuration
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

/// Store the data recieved
type OAuthToken {
  // TODO: Record expiry times
  OAuthToken(access: String, token_type: String)
}

fn save_token(token: OAuthToken, ctx: Context) -> Result(Nil, sqlight.Error) {
  // TODO: Rewrite in a way less prone to sql injection
  {
    "INSERT INTO google_oauth_tokens (access) VALUES ('" <> token.access <> "')"
  }
  |> sqlight.exec(ctx.database_connection)
}

/// Exchange an authorization code for oauth tokens
fn request_token(req: Request, ctx: Context) -> Result(OAuthToken, Nil) {
  // Extract authorization code from query string
  let query = wisp.get_query(req)
  use code <- result.try(list.key_find(query, "code"))

  // Prepare request for access token
  // This is a POST with a url encoded form body
  // The reponse body is JSON
  // Maybe the req body can be json too, but the form works fine
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
  use token_req <- result.try(request.to("https://oauth2.googleapis.com/token"))
  let token_req =
    token_req
    |> request.set_method(http.Post)
    |> request.set_header("content-type", "application/x-www-form-urlencoded")
    |> request.prepend_header("accept", "application/json")
    |> request.set_body(body)

  // Send token request
  // Replace the error type if we fail
  let resp = case hackney.send(token_req) {
    Ok(r) -> Ok(r)
    Error(e) -> {
      case e {
        hackney.InvalidUtf8Response ->
          wisp.log_warning("Token request failed: invalid utf-8 data")
        hackney.Other(e) -> {
          wisp.log_warning("Token request failed: unable to connect to host")
          echo e
          Nil
        }
      }
      Error(Nil)
    }
  }
  use resp <- result.try(resp)

  // Parse the response body and extract the access token
  // Return the token as an OAuthToken result
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
    // Apparently always 'Bearer' atm
    use token_type <- decode.field("token_type", decode.string)
    // TODO: Parse expiry times
    // They're given in seconds from the current time so we'll have to calculate
    // the associated unix epoch
    case string.lowercase(token_type) {
      "bearer" -> decode.success(OAuthToken(access_token, token_type))
      t -> {
        wisp.log_error(
          "Got unknown token type '" <> t <> "' instead of 'Bearer'",
        )
        decode.failure(OAuthToken(access_token, token_type), "token_type")
      }
    }
  }
  json.parse(resp_body, decoder)
  |> result.map_error(fn(_) {
    wisp.log_warning("Unable to decode access token")
    Nil
  })
}

/// This is the page Google redirects a user to on login
/// We validate the state to try and avoid CSRF
fn google_auth_callback(req: Request, ctx: Context) -> Response {
  use <- wisp.require_method(req, http.Get)
  use <- validate_state(req)

  // TODO: Make async with actor?
  case request_token(req, ctx) {
    Ok(token) -> {
      wisp.log_info("Login successful")
      case save_token(token, ctx) {
        Ok(_) -> Nil
        Error(e) -> {
          wisp.log_error("Unable to save token")
          echo e
          Nil
        }
      }
    }
    Error(_) -> wisp.log_warning("Login failed")
  }
  wisp.redirect("/")
}
