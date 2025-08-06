import gleam/dynamic/decode
import gleam/erlang/process
import gleam/hackney
import gleam/http
import gleam/http/request
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/result
import gleam/string
import gleam/string_tree
import gleam/time/duration
import gleam/time/timestamp
import gleam/uri
import mist
import rate_limiter
import wisp.{type Request, type Response}
import wisp/wisp_mist

import database/oauth/state as oauth_state
import database/oauth/tokens.{type OAuthToken}
import state.{type Context}

// ////////////// ENTRY POINT ///////////////

/// Entry point
/// Starts server
pub fn main() {
  wisp.configure_logger()

  let ctx = state.load_context()
  // There is no need for the secret key to be in the context
  let secret_key_base = state.get_env_var("FUC_SECRET_KEY")

  wisp.log_info("Context loaded")

  case ctx, secret_key_base {
    Ok(ctx), Ok(secret_key_base) -> {
      // Using a let assert because it simplifies the logic and we
      // *want* to panic if it fails
      let assert Ok(_) = rate_limiter.start_rate_limiter(ctx.rate_limiter)
      let server =
        route_request(_, ctx)
        |> wisp_mist.handler(secret_key_base)
        |> mist.new()
        |> mist.bind("localhost")
        |> mist.port(8000)
        |> mist.start()

      case server {
        Ok(_) -> process.sleep_forever()
        Error(e) -> {
          wisp.log_critical("Unable to start server: " <> string.inspect(e))
        }
      }
    }
    Error(e), Ok(_) -> {
      wisp.log_critical("Unable to load context: " <> string.inspect(e))
    }
    Ok(_), Error(e) -> {
      wisp.log_critical("Unable to load secret key base: " <> string.inspect(e))
    }
    Error(e_ctx), Error(e_sk) -> {
      wisp.log_critical(
        "Unable to load context or secret key.\nContext error: "
        <> string.inspect(e_ctx)
        <> "\nSecret key error: "
        <> string.inspect(e_sk),
      )
    }
  }

  wisp.log_info("Stopping...")
  process.sleep(500)
  // give logging a chance to finish
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
fn login_page(req: Request, ctx: Context) -> Response {
  use <- wisp.require_method(req, http.Get)

  let body =
    string_tree.from_string(
      "<a href='" <> ctx.address <> "/auth/google'>Login with Google</a>",
    )

  wisp.ok()
  |> wisp.html_body(body)
}

// /////////// OAUTH HANDLING /////////////////

/// Redirect to Google's OAuth login page
fn start_google_login(req: Request, ctx: Context) -> Response {
  use <- wisp.require_method(req, http.Get)
  let lifespan = 5 * 60
  let st =
    oauth_state.PendingStateToken(
      wisp.random_string(128),
      timestamp.system_time() |> timestamp.add(duration.seconds(lifespan)),
    )
  case oauth_state.insert_state_token(st, ctx.database_connection) {
    Ok(_) -> {
      let url =
        "https://accounts.google.com/o/oauth2/v2/auth?"
        <> "client_id="
        <> ctx.oauth_client.id
        <> "&redirect_uri="
        <> construct_callback_url(ctx)
        <> "&response_type=code"
        // Scopes are a space seperated list
        // Requested scopes: gmail.labels
        <> "&scope="
        <> uri.percent_encode("https://www.googleapis.com/auth/gmail.readonly")
        <> "&access_type=online"
        <> "&state="
        <> st.token
        <> "&nonce="
        <> wisp.random_string(64)
      // This uses a 303 redirect, which appears to be what is recommended for openid
      // https://openid.net/specs/openid-connect-core-1_0.html#HTTP307Redirects
      wisp.redirect(url)
      // I've checked the wisp source.
      // It uses the gleam/http/cookie defaults which include HttpOnly = true and SameSite = Lax
      // which seems about what we want.
      // Five minute timeout is trying to strike a balance between not lingering and
      // not expiring if the user takes a while to login
      |> wisp.set_cookie(req, "oauth_state", st.token, wisp.Signed, lifespan)
    }
    Error(e) -> {
      wisp.log_error("Unable to save state")
      echo e
      wisp.internal_server_error()
    }
  }
}

/// Returns the percent encoded URL used for OAuth redirect
fn construct_callback_url(ctx: Context) -> String {
  let full_address = ctx.address <> "/auth/callback"
  uri.percent_encode(full_address)
}

/// Middleware that asserts that the request has valid oauth state
fn validate_state(
  req: Request,
  ctx: Context,
  next: fn() -> Response,
) -> Response {
  let query = wisp.get_query(req)
  // Validate the state token matches the signed value on the client
  let state = {
    use remote <- result.try(
      list.key_find(query, "state")
      |> result.map_error(fn(_) { "State missing from query string" }),
    )
    use client <- result.try(
      wisp.get_cookie(req, "oauth_state", wisp.Signed)
      |> result.map_error(fn(_) { "State cookie not found or invalid" }),
    )
    case client == remote {
      True -> {
        let now = timestamp.system_time()
        case oauth_state.select_state_token(client, ctx.database_connection) {
          Some(st) -> {
            // We don't need to check that st.token == client == remote
            // because it is enforced by state.select_state_token()
            case timestamp.compare(now, st.expires_at) {
              order.Lt -> {
                case
                  oauth_state.delete_state_token(st, ctx.database_connection)
                {
                  Error(e) ->
                    Ok(wisp.log_warning(
                      "Unable to delete used state token: " <> string.inspect(e),
                    ))
                  Ok(Nil) -> Ok(Nil)
                }
              }
              _ -> Error("State has expired")
            }
          }
          None -> Error("State not in database")
        }
      }
      False -> Error("Client and remote states do not match")
    }
  }

  case state {
    Ok(_) -> next()
    Error(e) -> {
      wisp.log_warning("State validation failed: " <> e)
      wisp.bad_request()
    }
  }
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
      "bearer" ->
        decode.success(tokens.PendingOAuthToken(access_token, token_type))
      t -> {
        wisp.log_error(
          "Got unknown token type '" <> t <> "' instead of 'Bearer'",
        )
        decode.failure(
          tokens.PendingOAuthToken(access_token, token_type),
          "token_type",
        )
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
  use <- validate_state(req, ctx)

  // TODO: Make async with actor?
  case request_token(req, ctx) {
    Ok(token) -> {
      wisp.log_info("Login successful")
      case tokens.insert_access_token(token, ctx.database_connection) {
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

/// Middleware to grab access token before making requests
fn with_access_token(ctx: Context, next: fn(OAuthToken) -> Response) -> Response {
  case tokens.get_access_token(ctx.database_connection) {
    Some(token) -> next(token)
    None -> wisp.redirect(ctx.address <> "/auth/google")
  }
  // TODO: Validate token hasn't expired
}
