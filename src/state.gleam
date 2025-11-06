import database/database
import gleam/erlang/process
import gleam/result
import gleam/string
import glenvy/dotenv
import glenvy/env
import maw
import rate_limiter
import sqlight
import wisp

// /////////////// SERVER CONFIGURATION ///////////////////////

/// Errors reported during context parsing and other parts of startup
pub type ContextError {
  MissingVariable(key: String)
  ParsingError(value: String)
  Impossible(wtf: String)
  DatabaseError
  SqlightError(err: sqlight.Error)
  EnvError(env.Error)
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
  // First load environment variables from systemd credentials, if present
  case env.string("CREDENTIALS_DIRECTORY") {
    Ok(dir) ->
      case dotenv.load_from(dir <> "/fuc.env") {
        Ok(_) ->
          wisp.log_info(
            "Loaded credentials file from ${CREDENTIALS_DIRECTORY}/fuc.env",
          )
        Error(e) ->
          wisp.log_error(
            "Unable to read credentials file from ${CREDENTIALS_DIRECTORY}/fuc.env: \n"
            <> string.inspect(e),
          )
      }
    Error(env.NotFound(n)) ->
      wisp.log_info(
        "$" <> n <> " not found,falling back to environment variables",
      )
    Error(env.FailedToParse(n)) -> wisp.log_error("Unable to parse $" <> n)
  }

  // OAuth information gets a special type
  // This is probably overkill tbh
  use id <- result.try(
    env.string("FUC_OAUTH_CLIENT_ID") |> result.map_error(EnvError),
  )
  use secret <- result.try(
    env.string("FUC_OAUTH_CLIENT_SECRET") |> result.map_error(EnvError),
  )
  let oauth_client = OAuthClient(id, secret)

  use port <- result.try(env.int("FUC_PORT") |> result.map_error(EnvError))

  // We drop any trailing slashes from the address
  use address <- result.try(
    env.string("FUC_ADDRESS") |> result.map_error(EnvError),
  )
  let address = case string.last(address) {
    Ok("/") -> Ok(string.drop_end(address, 1))
    Ok(_) -> Ok(address)
    Error(_) ->
      Error(Impossible(
        "Address is empty despite get_env_var validating it isn't",
      ))
  }
  use address <- result.try(address)

  // Create the database as soon as we know what it is called
  // If we're running under systemd we use the STATE_DIRECTORY environment variable
  let database_path = {
    case env.string("STATE_DIRECTORY") {
      Ok(state_dir) -> {
        let first_dir = case string.split_once(state_dir, on: ":") {
          Ok(#(first, _)) -> first
          Error(Nil) -> state_dir
        }
        wisp.log_info(
          "Using systemd STATE_DIRECTORY for database (" <> state_dir <> ")",
        )
        Ok("file:" <> first_dir <> "/fuc.sqlite")
      }
      Error(env.NotFound(_)) ->
        env.string("FUC_DATABASE_PATH") |> result.map_error(EnvError)
      Error(e) -> Error(EnvError(e))
    }
  }
  use database_path <- result.try(database_path)

  wisp.log_info("Using database path " <> database_path)

  let conn =
    sqlight.open(database_path) |> result.map_error(fn(e) { SqlightError(e) })
  use conn <- result.try(conn)
  let conn =
    database.create_database(conn)
    |> result.replace_error(DatabaseError)
  use conn <- result.try(conn)

  use ao3_label <- result.try(
    env.string("FUC_AO3_LABEL") |> result.map_error(EnvError),
  )

  let rate_limiter = process.new_name("rate_limiter")
  let maw = process.new_name("maw")

  Context(
    oauth_client:,
    address:,
    port:,
    database_connection: conn,
    ao3_label:,
    rate_limiter:,
    maw:,
  )
  |> Ok
}
