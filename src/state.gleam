import gleam/int
import gleam/result
import gleam/string
import sqlight

import envoy

// /////////////// SERVER CONFIGURATION & STARTUP ///////////////////////

/// Errors reported during context parsing and other parts of startup
pub type ContextError {
  MissingVariable(key: String)
  ParsingError(value: String)
  Impossible(wtf: String)
  DatabaseError(err: sqlight.Error)
}

/// Context for server invocation
/// `oauth_client` supplies the id and secret for Google OAuth
/// `address` is the public facing address for the site, including protocol
/// and port and subfolder (if necessary)
/// e.g. https://thehivemind.gay:3000/fuq
/// Use the public facing domain and port as exposed by your reverse proxy
/// `port` this process should listen on. May differ from the port included in the address
/// `database_path` points to an sqlite3 database
pub type Context {
  Context(
    oauth_client: OAuthClient,
    address: String,
    port: Int,
    database_connection: sqlight.Connection,
  )
}

/// Basic abstraction for oauth client information
pub type OAuthClient {
  OAuthClient(id: String, secret: String)
}

/// Init context, loading information from environment variables
/// This calls create_database because it should be an error to have
/// a context with an invalid database referenced.
pub fn load_context() -> Result(Context, ContextError) {
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
pub fn get_env_var(name: String) -> Result(String, ContextError) {
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
) -> Result(sqlight.Connection, ContextError) {
  use conn <- result.try(
    create_table(conn, "google_oauth_tokens", [
      "id INTEGER PRIMARY KEY", "access TEXT UNIQUE NOT NULL",
    ]),
  )
  use conn <- result.try(
    create_table(conn, "google_oauth_state", [
      "id INTEGER PRIMARY KEY", "state TEXT UNIQUE NOT NULL",
    ]),
  )
  Ok(conn)
}

fn create_table(
  conn: sqlight.Connection,
  name: String,
  cols: List(String),
) -> Result(sqlight.Connection, ContextError) {
  let create =
    sqlight.exec(
      "CREATE TABLE IF NOT EXISTS"
        <> name
        <> "("
        <> string.join(cols, ",")
        <> ")",
      conn,
    )

  case create {
    Ok(Nil) -> Ok(conn)
    Error(e) -> Error(DatabaseError(e))
  }
}

/// Encapsulate oauth request metadata
/// The state needs to be in the url and stored seperately
pub type OAuthRequest {
  OAuthRequest(url: String, state: String)
}

pub fn save_state(req: OAuthRequest, ctx: Context) -> Result(Nil, sqlight.Error) {
  { "INSERT INTO google_oauth_state (state) VALUES ('" <> req.state <> "')" }
  |> sqlight.exec(ctx.database_connection)
}

/// Store the data recieved
pub type OAuthToken {
  // TODO: Record expiry times
  OAuthToken(access: String, token_type: String)
}

pub fn save_token(token: OAuthToken, ctx: Context) -> Result(Nil, sqlight.Error) {
  // TODO: Rewrite in a way less prone to sql injection
  {
    "INSERT INTO google_oauth_tokens (access) VALUES ('" <> token.access <> "')"
  }
  |> sqlight.exec(ctx.database_connection)
}
