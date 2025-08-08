import cake/adapter/sqlite
import cake/join
import cake/select
import cake/where
import database/update
import database/works
import gleam/dynamic/decode.{type Decoder}
import gleam/list
import sqlight.{type Connection, type Error}

fn prefix_strings(l: List(String), prefix: String) -> List(String) {
  use s <- list.map(l)
  prefix <> s
}

pub type WorkWithUpdateCount {
  WorkWithUpdateCount(id: Int, title: String, authors: String, count: Int)
}

fn update_count_from_sql() -> Decoder(WorkWithUpdateCount) {
  use id <- decode.field(0, decode.int)
  use title <- decode.field(1, decode.string)
  use authors <- decode.field(2, decode.string)
  use count <- decode.field(3, decode.int)
  WorkWithUpdateCount(id, title, authors, count) |> decode.success
}

pub fn select_works_with_updates(conn: Connection) -> Result(_, Error) {
  // let j =
  //   join.table(update.table_update)
  //   |> join.inner(
  //     where.col(works.table_work <> ".id")
  //       |> where.eq(where.col(update.table_update <> ".work_id")),
  //     "up",
  //   )

  let subq =
    select.new()
    |> select.from_table(update.table_update)
    |> select.select_col("work_id")
    |> select.select(select.col("COUNT(*)") |> select.alias("update_count"))
    |> select.group_by("work_id")
    |> select.to_query()

  select.new()
  |> select.from_table(works.table_work)
  |> select.join(
    join.sub_query(subq)
    |> join.inner(
      where.col(works.table_work <> ".id")
        |> where.eq(where.col("work_id")),
      "up",
    ),
  )
  |> select.select_cols(
    [".id", ".title", ".authors"] |> prefix_strings(works.table_work),
  )
  |> select.select_col("up.update_count")
  |> select.order_by_desc("up.update_count")
  |> select.to_query()
  |> sqlite.run_read_query(update_count_from_sql(), conn)
}
