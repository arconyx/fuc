import database/emails
import database/oauth/state
import database/oauth/tokens
import gleam/result
import sqlight

/// Init database with tables
/// This must be idempotent because it may be
/// called on existing databases
pub fn create_database(
  conn: sqlight.Connection,
) -> Result(sqlight.Connection, sqlight.Error) {
  use conn <- result.try(tokens.create_table(conn))
  use conn <- result.try(state.create_table(conn))
  emails.create_table(conn)
}
