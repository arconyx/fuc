// OAUTH STATE TOKEN
// Random string stored on client and server and passed with request
// We check the state token in auth callbacks against the saved values
// to ensure it is tied to a auth flow we started

import cake/adapter/sqlite
import cake/delete
import cake/insert
import cake/select
import cake/where
import database/internal.{type Error}
import gleam/dynamic/decode
import gleam/float
import gleam/list
import gleam/option.{type Option, None}
import gleam/result
import gleam/string
import gleam/time/timestamp.{type Timestamp}
import sqlight
import wisp

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
pub fn create_table(
  conn: sqlight.Connection,
) -> Result(sqlight.Connection, sqlight.Error) {
  internal.create_table(
    conn,
    table_oauth_state,
    [
      "id INTEGER PRIMARY KEY", "state TEXT UNIQUE NOT NULL",
      "expires_at INTEGER NOT NULL",
    ],
    False,
  )
}

/// Insert request state token into database
pub fn insert_state_token(
  state: OAuthStateToken,
  conn: sqlight.Connection,
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
  |> sqlite.run_write_query(oauth_state_from_sql(), conn)
}

/// Return state with matching token from database, if it exists
/// This MUST only return Some value iff the token value for the row
///  exactly matches the supplied token argument.
pub fn select_state_token(
  token: String,
  conn: sqlight.Connection,
) -> Option(OAuthStateToken) {
  let q =
    select.new()
    |> select.select_cols(["id", "state", "expires_at"])
    |> select.from_table(table_oauth_state)
    |> select.where(where.col("state") |> where.eq(where.string(token)))
    |> select.to_query
    |> sqlite.run_read_query(oauth_state_from_sql(), conn)

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
  conn: sqlight.Connection,
) -> Result(Nil, Error) {
  case token {
    PendingStateToken(_, _) -> Error(internal.NotARow)
    StateTokenRow(_, _, id) -> {
      delete.new()
      |> delete.where(where.col("id") |> where.eq(where.int(id)))
      |> delete.table(table_oauth_state)
      |> delete.no_returning
      |> delete.to_query
      |> sqlite.run_write_query(oauth_state_from_sql(), conn)
      |> result.replace(Nil)
      |> result.map_error(fn(e) { internal.SQLError(e) })
    }
  }
}
