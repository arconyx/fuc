import database/emails
import database/oauth/state
import database/oauth/tokens
import gleam/dynamic/decode
import gleam/string
import sqlight.{type Connection}

pub type Error {
  SQLError(sqlight.Error)
  PragmaError(String)
}

/// Init database with tables and pragmas
/// This must be idempotent because it may be
/// called on existing databases
pub fn create_database(conn: Connection) -> Result(Connection, Error) {
  use conn <- pragma_set(conn, "foreign_keys", "on", "1")
  // use conn <- pragma_set(conn, "journal_mode", "wal", "wal")
  use conn <- wrap_create_table(conn, tokens.create_table)
  use conn <- wrap_create_table(conn, state.create_table)
  use conn <- wrap_create_table(conn, emails.create_table)
  conn |> Ok
}

fn pragma_set(
  conn: Connection,
  key: String,
  value: String,
  expects: String,
  next: fn(Connection) -> Result(Connection, Error),
) -> Result(Connection, Error) {
  case
    sqlight.query(
      "PRAGMA " <> key <> " = " <> value <> ";",
      conn,
      [],
      decode.at([0], decode.string),
    )
  {
    Ok([v]) if v == expects -> next(conn)
    Error(e) ->
      PragmaError("Pragma set for " <> key <> " errored: " <> string.inspect(e))
      |> Error
    e ->
      PragmaError("Bad pragma for " <> key <> ": " <> string.inspect(e))
      |> Error
  }
}

/// Helper for chaining table creation and wrapping the errors
fn wrap_create_table(
  conn: Connection,
  create: fn(Connection) -> Result(Connection, sqlight.Error),
  next: fn(Connection) -> Result(Connection, Error),
) -> Result(Connection, Error) {
  case create(conn) {
    Ok(conn) -> next(conn)
    Error(e) -> SQLError(e) |> Error
  }
}
