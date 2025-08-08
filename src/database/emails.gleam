import cake/adapter/sqlite
import cake/insert
import cake/select
import cake/where
import database/internal
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None}
import gleam/string
import sqlight
import wisp

/// PROCESSED_MESSAGES
const table_email = "emails"

pub type Email {
  Email(id: String, success: Bool)
}

pub fn create_table(conn: sqlight.Connection) -> Result(sqlight.Connection, Nil) {
  internal.create_table(
    conn,
    table_email,
    ["gmail_id TEXT PRIMARY KEY", "success BOOLEAN"],
    True,
  )
}

fn email_from_sql() -> decode.Decoder(Email) {
  use id <- decode.field(0, decode.string)
  use success <- decode.field(1, sqlight.decode_bool())
  Email(id:, success:)
  |> decode.success()
}

pub fn insert_email(
  id: String,
  success: Bool,
  conn: sqlight.Connection,
) -> Result(List(Email), sqlight.Error) {
  [[insert.string(id), insert.bool(success)] |> insert.row]
  |> insert.from_values(table_name: table_email, columns: [
    "gmail_id",
    "success",
  ])
  |> insert.returning(["gmail_id", "success"])
  |> insert.to_query()
  |> sqlite.run_write_query(email_from_sql(), conn)
}

pub fn select_email(id: String, conn: sqlight.Connection) -> Option(Email) {
  let q =
    select.new()
    |> select.select_cols(["gmail_id", "success"])
    |> select.from_table(table_email)
    |> select.where(where.col("gmail_id") |> where.eq(where.string(id)))
    |> select.to_query
    |> sqlite.run_read_query(email_from_sql(), conn)

  case q {
    Error(e) -> {
      wisp.log_warning("Unable to fetch email: " <> string.inspect(e))
      None
    }
    Ok(v) -> list.first(v) |> option.from_result
  }
}
