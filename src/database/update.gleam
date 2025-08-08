import cake/adapter/sqlite
import cake/insert.{type InsertRow, type InsertValue}
import cake/select
import cake/where
import database/internal
import database/works
import gleam/dynamic/decode
import gleam/float
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/time/timestamp.{type Timestamp}
import sqlight.{type Connection, type Error}

pub const table_update = "updates"

// AO3 updates may be works or chapters
// Chapters have seperate titles and summaries to works
// We're going to ignore this distinction by setting the
// title of a work update to a default value like "Work Created"
// and setting the summary to None (since chapter summaries are optional)

pub type PendingUpdate {
  PendingUpdate(
    work_id: Int,
    chapter_id: Option(Int),
    title: String,
    summary: Option(String),
    time: Timestamp,
  )
}

pub type UpdateRow {
  UpdateRow(
    id: Int,
    work_id: Int,
    chapter_id: Option(Int),
    title: String,
    summary: Option(String),
    time: Timestamp,
  )
}

pub fn create_table(conn: Connection) -> Result(Connection, Nil) {
  internal.create_table(
    conn,
    table_update,
    [
      "id INTEGER PRIMARY KEY",
      "work_id INTEGER NOT NULL",
      "chapter_id INTEGER",
      "title TEXT NOT NULL",
      "summary TEXT",
      "time INTEGER NOT NULL",
      "FOREIGN KEY(work_id) REFERENCES " <> works.table_work <> "(id)",
    ],
    False,
  )
}

fn option_to_sql(op: Option(a), to_sql: fn(a) -> InsertValue) -> InsertValue {
  case op {
    Some(a) -> to_sql(a)
    None -> insert.null()
  }
}

fn update_to_sql(update: PendingUpdate) -> InsertRow {
  [
    update.work_id |> insert.int,
    update.chapter_id |> option_to_sql(insert.int),
    update.title |> insert.string,
    update.summary |> option_to_sql(insert.string),
    update.time |> timestamp.to_unix_seconds |> float.truncate |> insert.int,
  ]
  |> insert.row
}

fn update_from_sql() -> decode.Decoder(UpdateRow) {
  use id <- decode.field(0, decode.int)
  use work_id <- decode.field(1, decode.int)
  use chapter_id <- decode.field(2, decode.optional(decode.int))
  use title <- decode.field(3, decode.string)
  use summary <- decode.field(4, decode.optional(decode.string))
  use time <- decode.field(5, decode.int)
  UpdateRow(
    id,
    work_id,
    chapter_id,
    title,
    summary,
    timestamp.from_unix_seconds(time),
  )
  |> decode.success
}

pub fn insert_updates(
  updates: List(PendingUpdate),
  conn: Connection,
) -> Result(Nil, Error) {
  insert.from_records(
    table_update,
    ["work_id", "chapter_id", "title", "summary", "time"],
    updates,
    update_to_sql,
  )
  |> insert.no_returning()
  |> insert.to_query
  |> sqlite.run_write_query(decode.dynamic, conn)
  |> result.replace(Nil)
}

pub fn select_updates_for_work(
  work_id: Int,
  conn: Connection,
) -> Result(List(UpdateRow), Error) {
  select.new()
  |> select.select_cols(["id", "work_id", "chapter_id", "title", "summary"])
  |> select.from_table(table_update)
  |> select.where(where.col("work_id") |> where.eq(where.int(work_id)))
  |> select.to_query
  |> sqlite.run_read_query(update_from_sql(), conn)
}
