import cake/adapter/sqlite
import cake/insert.{type InsertRow, type InsertValue}
import cake/select
import cake/update
import cake/where
import database/internal
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import sqlight.{type Connection, type Error}

pub const table_work = "works"

// TODO: Consider setting WAL on database

/// AO3 emails only include full details for a work once per email
/// We only allow inserting these detailed emails into the database
// This should be fine so long as we do all work insertions for an update
// before any update insertions (as every email includes detailed information
// for all its works)
// We use this type instead of the Work type in parser.gleam to make passing
// a SparseWork impossible
pub type Work {
  Work(
    id: Int,
    title: String,
    authors: String,
    chapters: String,
    fandom: String,
    rating: String,
    warnings: String,
    series: Option(String),
    summary: Option(String),
  )
}

pub fn create_table(conn: Connection) -> Result(Connection, Nil) {
  internal.create_table(
    conn,
    table_work,
    [
      "id INTEGER PRIMARY KEY", "title TEXT NOT NULL", "authors TEXT NOT NULL",
      "chapters TEXT NOT NULL", "fandom TEXT NOT NULL", "rating TEXT NOT NULL",
      "warnings TEXT NOT NULL", "series TEXT", "summary TEXT",
    ],
    False,
  )
}

// I was going to track update times to ensure that we don't overwrite metadata with
// outdated data from old emails but that's only a concern on initial sync.
// Lets ignore it.

/// Unwraps an option to an InsertValue that is null if the `op` is None
fn option_to_sql(op: Option(a), to_sql: fn(a) -> InsertValue) -> InsertValue {
  case op {
    Some(a) -> to_sql(a)
    None -> insert.null()
  }
}

fn work_to_sql(work: Work) -> InsertRow {
  [
    work.id |> insert.int,
    work.title |> insert.string,
    work.authors |> insert.string,
    work.chapters |> insert.string,
    work.fandom |> insert.string,
    work.rating |> insert.string,
    work.warnings |> insert.string,
    option_to_sql(work.series, insert.string),
    option_to_sql(work.summary, insert.string),
  ]
  |> insert.row
}

fn work_from_sql() -> decode.Decoder(Work) {
  use id <- decode.field(0, decode.int)
  use title <- decode.field(1, decode.string)
  use authors <- decode.field(2, decode.string)
  use chapters <- decode.field(3, decode.string)
  use fandom <- decode.field(4, decode.string)
  use rating <- decode.field(5, decode.string)
  use warnings <- decode.field(6, decode.string)
  use series <- decode.field(7, decode.optional(decode.string))
  use summary <- decode.field(8, decode.optional(decode.string))
  Work(id, title, authors, chapters, fandom, rating, warnings, series, summary)
  |> decode.success
}

pub fn insert_works(works: List(Work), conn: Connection) -> Result(Nil, Error) {
  works
  |> insert.from_records(
    table_work,
    [
      "id", "title", "authors", "chapters", "fandom", "rating", "warnings",
      "series", "summary",
    ],
    _,
    work_to_sql,
  )
  |> insert.on_columns_conflict_update(
    ["id"],
    where.none(),
    update.new()
      |> update.sets([
        "title" |> update.set_expression("excluded.title"),
        "authors" |> update.set_expression("excluded.authors"),
        "chapters" |> update.set_expression("excluded.chapters"),
        "fandom" |> update.set_expression("excluded.fandom"),
        "rating" |> update.set_expression("excluded.rating"),
        "warnings" |> update.set_expression("excluded.warnings"),
        "series" |> update.set_expression("excluded.series"),
        "summary" |> update.set_expression("excluded.summary"),
      ]),
  )
  |> insert.no_returning
  |> insert.to_query
  |> sqlite.run_write_query(decode.dynamic, conn)
  |> result.replace(Nil)
}

pub fn select_works(
  ids: List(Int),
  conn: Connection,
) -> Result(List(Work), Error) {
  select.new()
  |> select.select_cols([
    "id", "title", "authors", "chapters", "fandom", "rating", "warnings",
    "series", "summary",
  ])
  |> select.from_table(table_work)
  |> select.where(where.col("id") |> where.in(ids |> list.map(where.int)))
  |> select.to_query
  |> sqlite.run_read_query(work_from_sql(), conn)
}
