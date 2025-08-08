import database/emails
import database/oauth/state
import database/oauth/tokens
import database/update
import database/works
import gleam/dynamic/decode
import gleam/result
import gleam/string
import sqlight.{type Connection}
import wisp

/// Init database with tables and pragmas
/// This must be idempotent because it may be
/// called on existing databases
pub fn create_database(conn: Connection) -> Result(Connection, Nil) {
  use conn <- pragma_set(conn, "foreign_keys", "on", 1, decode.int)
  // use conn <- pragma_set(conn, "journal_mode", "wal", "wal")
  use conn <- result.try(tokens.create_table(conn))
  use conn <- result.try(state.create_table(conn))
  use conn <- result.try(emails.create_table(conn))
  use conn <- result.try(works.create_table(conn))
  use conn <- result.try(update.create_table(conn))
  conn |> Ok
}

fn pragma_set(
  conn: Connection,
  key: String,
  value: String,
  expects: a,
  decoder: decode.Decoder(a),
  next: fn(Connection) -> Result(Connection, Nil),
) -> Result(Connection, Nil) {
  // Set pragma
  let pragma_str = "PRAGMA " <> key <> " = " <> value
  let set =
    sqlight.exec(pragma_str, conn)
    |> result.map_error(fn(e) {
      wisp.log_error(
        "Unable to set pragma\n"
        <> pragma_str
        <> "\n due to error\n"
        <> string.inspect(e),
      )
    })
  use _ <- result.try(set)

  // Query new pragma value
  let check = sqlight.query("PRAGMA " <> key, conn, [], decode.at([0], decoder))
  case check {
    Ok([v]) if v == expects -> next(conn)
    Ok(e) -> {
      wisp.log_error("Bad pragma for " <> key <> ": " <> string.inspect(e))
      Nil |> Error
    }
    Error(e) -> {
      wisp.log_error(
        "Unable to query pragma "
        <> key
        <> "due to error\n"
        <> string.inspect(e),
      )
      Nil |> Error
    }
  }
}
