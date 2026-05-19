import fuc/database/database
import fuc/env
import fuc/maw
import fuc/rate_limiter
import gleam/erlang/process
import gleam/int
import gleam/result
import gleam/string
import logging
import sqlight

// /////////////// SERVER CONFIGURATION ///////////////////////

/// Errors reported during context parsing and other parts of startup
pub type ContextError {
  MissingVariable(key: String)
  ParsingError(key: String, value: String)
  Impossible(wtf: String)
  DatabaseError
  SqlightError(err: sqlight.Error)
  UnableToSetEnv
  UnableToReadEnvFile
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
    maw: process.Name(maw.Message),
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
  // First load environment variables from systemd credentials, if present.
  let env = env.load_env_from_systemd()

  let get = fn(key) {
    case env.get(env, key) {
      Ok(v) -> Ok(v)
      Error(_) -> MissingVariable(key) |> Error
    }
  }

  use id <- result.try(get("FUC_OAUTH_CLIENT_ID"))
  use secret <- result.try(get("FUC_OAUTH_CLIENT_SECRET"))
  let oauth_client = OAuthClient(id, secret)

  let port = case get("FUC_PORT") {
    Ok(port_str) ->
      case int.parse(port_str) {
        Ok(port) -> Ok(port)
        Error(_) -> ParsingError(key: "FUC_PORT", value: port_str) |> Error
      }
    Error(e) -> Error(e)
  }
  use port <- result.try(port)

  // We drop any trailing slashes from the address
  let address = get("FUC_ADDRESS") |> result.map(string.remove_suffix(_, "/"))
  use address <- result.try(address)

  // Create the database as soon as we know what it is called
  // If we're running under systemd we use the STATE_DIRECTORY environment variable
  let database_path = {
    case get("STATE_DIRECTORY") {
      Ok(state_dir) -> {
        let first_dir = case string.split_once(state_dir, on: ":") {
          Ok(#(first, _)) -> first
          Error(Nil) -> state_dir
        }
        logging.log(
          logging.Info,
          "Using systemd STATE_DIRECTORY for database (" <> state_dir <> ")",
        )
        Ok("file:" <> first_dir <> "/fuc.sqlite")
      }
      Error(_) -> get("FUC_DATABASE_PATH")
    }
  }
  use database_path <- result.try(database_path)
  logging.log(logging.Info, "Using database path " <> database_path)

  use database_connection <- result.try(
    sqlight.open(database_path) |> result.map_error(fn(e) { SqlightError(e) }),
  )
  use database_connection <- result.try(
    database.create_database(database_connection)
    |> result.replace_error(DatabaseError),
  )

  use ao3_label <- result.try(get("FUC_AO3_LABEL"))

  Context(
    oauth_client:,
    address:,
    port:,
    database_connection:,
    ao3_label:,
    rate_limiter: process.new_name("rate_limiter"),
    maw: process.new_name("maw"),
  )
  |> Ok
}
