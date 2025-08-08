import database/database
import envoy
import gleam/erlang/process
import gleam/int
import gleam/result
import gleam/string
import rate_limiter
import sqlight

// /////////////// SERVER CONFIGURATION ///////////////////////

/// Errors reported during context parsing and other parts of startup
pub type ContextError {
  MissingVariable(key: String)
  ParsingError(value: String)
  Impossible(wtf: String)
  DatabaseError
  SqlightError(err: sqlight.Error)
}

/// Context for server invocation
/// `oauth_client` supplies the id and secret for Google OAuth
/// `address` is the public facing address for the site, including protocol
/// and port and subfolder (if necessary)
/// e.g. https://thehivemind.gay:3000/fuq
/// Use the public facing domain and port as exposed by your reverse proxy
/// `port` this process should listen on. May differ from the port included in the address
/// `database_path` points to an sqlite3 database
/// `ao3_label` is the id of the gmail label used to flag relevant emails
pub type Context {
  Context(
    oauth_client: OAuthClient,
    address: String,
    port: Int,
    database_connection: sqlight.Connection,
    ao3_label: String,
    rate_limiter: process.Name(rate_limiter.Message),
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
    sqlight.open(database_path) |> result.map_error(fn(e) { SqlightError(e) })
  use conn <- result.try(conn)
  let conn =
    database.create_database(conn)
    |> result.replace_error(DatabaseError)
  use conn <- result.try(conn)

  use ao3_label <- result.try(get_env_var("FUC_AO3_LABEL"))

  let rl_name = process.new_name("rate_limiter")

  Context(client, addr, port, conn, ao3_label, rl_name) |> Ok
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
