import cake/adapter/sqlite
import cake/insert.{type InsertRow}
import cake/update
import cake/where
import database/internal
import database/oauth/tokens
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option}
import gleam/result
import sqlight.{type Connection, type Error}

const table_work = "works"

// TODO: Consider setting WAL on database

/// AO3 emails only include full details for a work once per email
/// For all successive works we can only get the title and id
/// We model this as a DetailedWork and a SparseWork
pub type Work {
  DetailedWork(
    id: Int,
    title: String,
    authors: String,
    chapters: String,
    fandom: String,
    rating: String,
    warnings: String,
    // relationships: Option(String),
    // character: Option(String),
    // additional_tags: Option(String),
    series: Option(String),
    summary: Option(String),
  )
  SparseWork(id: Int, title: String)
}

pub fn create_table(conn: Connection) -> Result(Connection, Error) {
  internal.create_table(
    conn,
    table_work,
    [
      "id INTEGER PRIMARY KEY", "title TEXT NOT NULL", "authors TEXT",
      "chapters TEXT", "fandom TEXT", "rating TEXT", "warnings TEXT",
      "series TEXT", "summary TEXT",
    ],
    False,
  )
}

// I was going to track update times to ensure that we don't overwrite metadata with
// outdated data from old emails but that's only a concern on initial sync.
// Lets ignore it.

fn work_to_sql(work: Work) -> InsertRow {
  case work {
    SparseWork(id, title) ->
      [insert.int(id), insert.string(title)] |> insert.row
    DetailedWork(..) ->
      [
        insert.int(work.id),
        insert.string(work.title),
        insert.string(work.authors),
        insert.string(work.chapters),
        insert.string(work.fandom),
        insert.string(work.rating),
        insert.string(work.warnings),
        work.series
          |> option.map(insert.string)
          |> option.lazy_unwrap(insert.null),
        work.summary
          |> option.map(insert.string)
          |> option.lazy_unwrap(insert.null),
      ]
      |> insert.row
  }
}

fn is_detailed(work: Work) {
  case work {
    DetailedWork(..) -> True
    SparseWork(..) -> False
  }
}

/// Please call this inside a transcation
/// It has two seperate write operations and no way to rollback both if one fails
pub fn insert_works(works: List(Work), conn: Connection) -> Result(Nil, Error) {
  let #(detailed, sparse) = list.partition(works, is_detailed)

  let detailed_query = case detailed {
    [] -> option.None
    _ ->
      detailed
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
      |> insert.to_query
      |> option.Some
  }

  let sparse_query = case sparse {
    [] -> option.None
    _ ->
      sparse
      |> insert.from_records(table_work, ["id", "title"], _, work_to_sql)
      |> insert.on_columns_conflict_update(
        ["id"],
        where.none(),
        update.new()
          |> update.sets(["title" |> update.set_expression("excluded.title")]),
      )
      |> insert.to_query
      |> option.Some
  }

  let detailed_res =
    option.map(detailed_query, fn(q) {
      sqlite.run_write_query(q, decode.dynamic, conn)
    })
  let sparse_res =
    option.map(sparse_query, fn(q) {
      sqlite.run_write_query(q, decode.dynamic, conn)
    })

  option.values([detailed_res, sparse_res]) |> result.all |> result.replace(Nil)
}
