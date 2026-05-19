import database/database
import envoy
import gleam/bit_array
import gleam/bool
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import maw
import rate_limiter
import sqlight
import wisp

// /////////////// SERVER CONFIGURATION ///////////////////////

/// Errors reported during context parsing and other parts of startup
pub type ContextError {
  MissingVariable
  ParsingError
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
  // First load environment variables from systemd credentials, if present
  case envoy.get("CREDENTIALS_DIRECTORY") {
    Ok(dir) -> {
      let file = dir <> "/fuc.env"
      case load_env(file) {
        Ok(_) -> wisp.log_info("Loaded credentials file from " <> file)
        Error(e) ->
          wisp.log_error(
            "Unable to read credentials file from "
            <> file
            <> ": \n"
            <> string.inspect(e),
          )
      }
    }
    Error(Nil) ->
      wisp.log_info(
        "$CREDENTIALS_DIRECTORY not found, falling back to environment variables",
      )
  }

  // OAuth information gets a special type
  // This is probably overkill tbh
  use id <- result.try(
    envoy.get("FUC_OAUTH_CLIENT_ID") |> result.replace_error(MissingVariable),
  )
  use secret <- result.try(
    envoy.get("FUC_OAUTH_CLIENT_SECRET")
    |> result.replace_error(MissingVariable),
  )
  let oauth_client = OAuthClient(id, secret)

  use port <- result.try(
    envoy.get("FUC_PORT")
    |> result.try(int.parse)
    |> result.replace_error(MissingVariable),
  )

  // We drop any trailing slashes from the address
  use address <- result.try(
    envoy.get("FUC_ADDRESS") |> result.replace_error(MissingVariable),
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
    case envoy.get("STATE_DIRECTORY") {
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
      Error(Nil) ->
        envoy.get("FUC_DATABASE_PATH") |> result.replace_error(MissingVariable)
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
    envoy.get("FUC_AO3_LABEL") |> result.replace_error(MissingVariable),
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

fn load_env(from: String) {
  case read_file_bits(from) {
    Ok(binary) ->
      case bit_array.to_string(binary) {
        Ok(envstr) ->
          envstr
          |> string.split("\n")
          |> list.map(string.trim)
          |> list.filter(fn(line) { line != "" })
          |> list.filter(fn(line) { bool.negate(string.starts_with(line, "#")) })
          |> list.try_map(fn(line) {
            case string.split_once(line, "=") {
              Ok(#(key, value)) -> {
                let key = string.trim(key)
                let value = string.trim(value)
                case string.is_empty(key) {
                  True -> Nil |> Error
                  // Will this have issues with "quoted values"?
                  False -> envoy.set(key, value) |> Ok
                }
              }
              Error(Nil) -> Nil |> Error
            }
          })
        Error(_) -> Error(Nil)
      }
    Error(_) -> Error(Nil)
  }
}

@external(erlang, "fuc_ffi", "read_file")
fn read_file_bits(filepath: String) -> Result(BitArray, Nil)
