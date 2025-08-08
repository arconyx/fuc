import cake/adapter/sqlite
import cake/insert
import cake/select
import database/internal
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None}
import gleam/string
import sqlight
import wisp

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
pub fn create_table(conn: sqlight.Connection) -> Result(sqlight.Connection, Nil) {
  internal.create_table(
    conn,
    table_oauth_tokens,
    ["id INTEGER PRIMARY KEY", "access TEXT UNIQUE NOT NULL"],
    False,
  )
}

/// Insert access token into database
pub fn insert_access_token(
  token: OAuthToken,
  conn: sqlight.Connection,
) -> Result(List(OAuthToken), sqlight.Error) {
  // TODO: Rewrite in a way less prone to sql injection
  [[insert.string(token.access)] |> insert.row]
  |> insert.from_values(table_name: table_oauth_tokens, columns: ["access"])
  |> insert.returning(["id", "access"])
  |> insert.to_query()
  |> sqlite.run_write_query(oauth_token_from_sql(), conn)
}

/// Get latest access token
pub fn get_access_token(conn: sqlight.Connection) -> Option(OAuthToken) {
  let s =
    select.new()
    |> select.select_cols(["id", "access"])
    |> select.from_table(table_oauth_tokens)
    |> select.order_by_desc("id")
    // hack for latest
    |> select.limit(1)
    |> select.to_query
    |> sqlite.run_read_query(oauth_token_from_sql(), conn)
  case s {
    Error(e) -> {
      wisp.log_warning("Unable to get access token: " <> string.inspect(e))
      None
    }
    Ok(v) -> list.first(v) |> option.from_result
  }
}
