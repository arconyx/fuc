import gleam/result
import gleam/string
import sqlight.{type Connection}

/// General error type for database stuff
pub type Error {
  // For types that don't correspond to a database row, like PendingStateToken
  NotARow
  // Generic SQLite erros
  SQLError(err: sqlight.Error)
}

/// Wrapper for creating a table from a list of columns
/// Favour `without_rowid: False`
/// https://www.sqlite.org/withoutrowid.html
pub fn create_table(
  conn: Connection,
  name: String,
  cols: List(String),
  without_rowid: Bool,
  // prefer false
) -> Result(Connection, sqlight.Error) {
  let query =
    "CREATE TABLE IF NOT EXISTS "
    <> name
    <> "("
    <> string.join(cols, ",")
    <> ")"
  let query = case without_rowid {
    True -> query <> " WITHOUT ROWID"
    False -> query
  }
  sqlight.exec(query, conn)
  |> result.map(fn(_) { conn })
}
