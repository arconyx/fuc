import cake/adapter/sqlite
import cake/delete
import cake/insert
import cake/select
import cake/where
import envoy
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None}
import gleam/result
import gleam/string
import gleam/time/timestamp.{type Timestamp}
import sqlight
import wisp

// /////////////// SERVER CONFIGURATION ///////////////////////

/// Errors reported during context parsing and other parts of startup
pub type ContextError {
  MissingVariable(key: String)
  ParsingError(value: String)
  Impossible(wtf: String)
  DatabaseInitError(err: sqlight.Error)
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
    |> result.map_error(fn(e) { DatabaseInitError(e) })
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
  {
    use conn <- result.try(create_table_access_tokens(conn))
    use conn <- result.try(create_table_state_tokens(conn))
    Ok(conn)
  }
  |> result.map_error(fn(e) { DatabaseInitError(e) })
}

/// Wrapper for creating a table from a list of columns
fn create_table(
  conn: sqlight.Connection,
  name: String,
  cols: List(String),
) -> Result(sqlight.Connection, sqlight.Error) {
  sqlight.exec(
    "CREATE TABLE IF NOT EXISTS "
      <> name
      <> "("
      <> string.join(cols, ",")
      <> ")",
    conn,
  )
  |> result.map(fn(_) { conn })
}

/// General error type for database stuff
pub type DatabaseError {
  // For types that don't correspond to a database row, like PendingStateToken
  NotARow
  // Generic SQLite erros
  SQLError(err: sqlight.Error)
}

// OAUTH STATE TOKEN
// Random string stored on client and server and passed with request
// We check the state token in auth callbacks against the saved values
// to ensure it is tied to a auth flow we started

const table_oauth_state = "google_oauth_state"

pub type OAuthStateToken {
  PendingStateToken(token: String, expires_at: Timestamp)
  StateTokenRow(token: String, expires_at: Timestamp, id: Int)
}

fn oauth_state_from_sql() -> decode.Decoder(OAuthStateToken) {
  use id <- decode.field(0, decode.int)
  use token <- decode.field(1, decode.string)
  use expiry <- decode.field(2, decode.int)
  StateTokenRow(token:, expires_at: timestamp.from_unix_seconds(expiry), id:)
  |> decode.success()
}

/// Create the table used to store state tokens
fn create_table_state_tokens(
  conn: sqlight.Connection,
) -> Result(sqlight.Connection, sqlight.Error) {
  create_table(conn, table_oauth_state, [
    "id INTEGER PRIMARY KEY", "state TEXT UNIQUE NOT NULL",
    "expires_at INTEGER NOT NULL",
  ])
}

/// Insert request state token into database
pub fn insert_state_token(
  state: OAuthStateToken,
  ctx: Context,
) -> Result(List(OAuthStateToken), sqlight.Error) {
  [
    [
      insert.string(state.token),
      insert.int(
        state.expires_at |> timestamp.to_unix_seconds |> float.truncate,
      ),
    ]
    |> insert.row,
  ]
  |> insert.from_values(table_name: table_oauth_state, columns: [
    "state", "expires_at",
  ])
  |> insert.returning(["id", "state", "expires_at"])
  |> insert.to_query
  |> sqlite.run_write_query(oauth_state_from_sql(), ctx.database_connection)
}

/// Return state with matching token from database, if it exists
/// This MUST only return Some value iff the token value for the row
///  exactly matches the supplied token argument.
pub fn select_state_token(
  token: String,
  ctx: Context,
) -> Option(OAuthStateToken) {
  let q =
    select.new()
    |> select.select_cols(["id", "state", "expires_at"])
    |> select.from_table(table_oauth_state)
    |> select.where(where.col("state") |> where.eq(where.string(token)))
    |> select.to_query
    |> sqlite.run_read_query(oauth_state_from_sql(), ctx.database_connection)

  case q {
    Error(e) -> {
      wisp.log_warning("Unable to fetch state token: " <> string.inspect(e))
      None
    }
    Ok(v) -> list.first(v) |> option.from_result
  }
}

/// Delete state token from database based on id
pub fn delete_state_token(
  token: OAuthStateToken,
  ctx: Context,
) -> Result(Nil, DatabaseError) {
  case token {
    PendingStateToken(_, _) -> Error(NotARow)
    StateTokenRow(_, _, id) -> {
      delete.new()
      |> delete.where(where.col("id") |> where.eq(where.int(id)))
      |> delete.table(table_oauth_state)
      |> delete.no_returning
      |> delete.to_query
      |> sqlite.run_write_query(oauth_state_from_sql(), ctx.database_connection)
      |> result.replace(Nil)
      |> result.map_error(fn(e) { SQLError(e) })
    }
  }
}

/// OAUTH ACCESS TOKEN
/// Returned by the oauth flow, gives api access
pub type OAuthToken {
  // TODO: Record expiry times
  PendingOAuthToken(access: String, token_type: String)
  OAuthTokenRow(access: String, token_type: String, id: Int)
}

const table_oauth_tokens = "google_oauth_tokens"

fn oauth_token_from_sql() -> decode.Decoder(OAuthToken) {
  use id <- decode.field(0, decode.int)
  use access <- decode.field(1, decode.string)
  // TODO: Maybe we shouldn't hardcode bearer
  OAuthTokenRow(access, "Bearer", id:)
  |> decode.success()
}

/// Create table for storing oauth access tokens
fn create_table_access_tokens(
  conn: sqlight.Connection,
) -> Result(sqlight.Connection, sqlight.Error) {
  create_table(conn, table_oauth_tokens, [
    "id INTEGER PRIMARY KEY", "access TEXT UNIQUE NOT NULL",
  ])
}

/// Insert access token into database
pub fn insert_access_token(
  token: OAuthToken,
  ctx: Context,
) -> Result(List(OAuthToken), sqlight.Error) {
  // TODO: Rewrite in a way less prone to sql injection
  [[insert.string(token.access)] |> insert.row]
  |> insert.from_values(table_name: table_oauth_tokens, columns: ["access"])
  |> insert.returning(["id", "access"])
  |> insert.to_query()
  |> sqlite.run_write_query(oauth_token_from_sql(), ctx.database_connection)
}

/// Get latest access token
pub fn get_access_token(ctx: Context) -> Option(OAuthToken) {
  let s =
    select.new()
    |> select.select_cols(["id", "access"])
    |> select.from_table(table_oauth_tokens)
    |> select.order_by_desc("id")
    // hack for latest
    |> select.limit(1)
    |> select.to_query
    |> sqlite.run_read_query(oauth_token_from_sql(), ctx.database_connection)
  case s {
    Error(e) -> {
      wisp.log_warning("Unable to get access token: " <> string.inspect(e))
      None
    }
    Ok(v) -> list.first(v) |> option.from_result
  }
}
