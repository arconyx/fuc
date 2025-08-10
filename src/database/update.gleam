import cake/adapter/sqlite
import cake/delete
import cake/insert.{type InsertRow, type InsertValue}
import cake/select
import cake/where
import database/internal
import database/works
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp.{type Timestamp}
import sqlight.{type Connection, type Error}
import wisp

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
  |> select.select_cols([
    "id",
    "work_id",
    "chapter_id",
    "title",
    "summary",
    "time",
  ])
  |> select.from_table(table_update)
  |> select.where(where.col("work_id") |> where.eq(where.int(work_id)))
  |> select.order_by_desc("time")
  |> select.order_by_desc("title")
  // hack to order by chapter number
  |> select.to_query
  |> sqlite.run_read_query(update_from_sql(), conn)
}

// I wanted to make the first arg an UpdateRow but the caller
// only gets the id from the url
pub fn delete_update(
  conn: Connection,
  work_id work_id: Int,
  update_id update_id: Int,
) -> Result(List(UpdateRow), Error) {
  let q =
    delete.new()
    |> delete.table(table_update)
    |> delete.where(
      where.and([
        where.col("id") |> where.eq(where.int(update_id)),
        where.col("work_id") |> where.eq(where.int(work_id)),
      ]),
    )
    |> delete.returning([
      "id",
      "work_id",
      "chapter_id",
      "title",
      "summary",
      "time",
    ])
    |> delete.to_query
    |> sqlite.run_write_query(update_from_sql(), conn)

  case q {
    Ok([update]) -> {
      wisp.log_info("Deleted update:\n" <> string.inspect(update))
      Ok([update])
    }
    Ok([]) -> {
      wisp.log_warning(
        "Tried to delete update "
        <> int.to_string(update_id)
        <> " from work "
        <> int.to_string(work_id)
        <> " but no matching updates found",
      )
      Ok([])
    }
    Ok(updates) -> {
      wisp.log_critical(
        "Deleted multiple works instead of only one!\nUpdate id: "
        <> int.to_string(update_id)
        <> ", work id: "
        <> int.to_string(work_id)
        <> "\nUpdates:\n"
        <> string.inspect(updates),
      )
      // TODO: Handle this better
      // We can't panic since systemd will just restart it.
      Ok(updates)
    }
    Error(e) -> Error(e)
  }
}

pub fn delete_updates_for_work(
  work_id: Int,
  conn: Connection,
) -> Result(List(UpdateRow), Error) {
  let q =
    delete.new()
    |> delete.table(table_update)
    |> delete.where(where.col("work_id") |> where.eq(where.int(work_id)))
    |> delete.returning([
      "id",
      "work_id",
      "chapter_id",
      "title",
      "summary",
      "time",
    ])
    |> delete.to_query
    |> sqlite.run_write_query(update_from_sql(), conn)

  case q {
    Ok([]) -> {
      wisp.log_warning(
        "Tried to delete updates for work "
        <> int.to_string(work_id)
        <> " but no matching updates found",
      )
      Ok([])
    }

    Ok(updates) -> {
      wisp.log_info("Deleted updates:\n" <> string.inspect(updates))
      Ok(updates)
    }
    Error(e) -> Error(e)
  }
}
