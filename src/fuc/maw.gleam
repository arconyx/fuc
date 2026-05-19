//// The Maw eats email ids and spits out parsed updates
//// 
//// This module defines an actor that directs the fetching
//// and parsing of individual emails.

import fuc/database/emails
import fuc/database/oauth/tokens.{type OAuthToken}
import fuc/database/update
import fuc/database/works
import fuc/gmail
import fuc/parser.{type ArchiveUpdate}
import fuc/rate_limiter
import gleam/bool
import gleam/dynamic/decode
import gleam/erlang/process.{type Name, type Subject}
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/set.{type Set}
import gleam/string
import gleam/time/timestamp.{type Timestamp}
import sqlight
import wisp

pub fn awaken_the_maw(
  conn: sqlight.Connection,
  ao3_label: String,
  rate_limiter: process.Name(rate_limiter.Message),
  maw: process.Name(Message),
  token: OAuthToken,
) -> Result(Nil, Nil) {
  let api_ctx = APIContext(conn, ao3_label, rate_limiter, token)
  case start_mail_manager(api_ctx, maw) {
    Ok(manager) -> {
      process.spawn(fn() { feed_maw(manager.data, api_ctx, None) })
      Nil |> Ok
    }
    Error(_) -> {
      wisp.log_error("Unable to start mail manager")
      Nil |> Error
    }
  }
}

pub type QueueStatus {
  QueueStatus(active: Int, successes: Int, failures: Int)
}

pub type Message {
  /// Queue an email for processing
  Queue(id: String, manager: Subject(Message))
  /// Mark an email as processed (success)
  Finish(id: String)
  /// Start a new worker for an email (failure)
  Restart(id: String, manager: Subject(Message))
  /// Abandon processing (failure)
  Abandon(id: String)
  // Abandon processing without marking as a failure
  Cancel(id: String)
  /// Shutdown all processing
  Die
  /// Get queue data
  GetStatus(reply: Subject(QueueStatus))
}

type APIContext {
  APIContext(
    db: sqlight.Connection,
    label: String,
    limiter: Name(rate_limiter.Message),
    token: OAuthToken,
  )
}

type State {
  State(
    active: Set(String),
    ctx: APIContext,
    /// Number of messages being processed
    processing: Int,
    /// Number of messages successfully processed
    successes: Int,
    /// Number of failures encountered during processing.
    /// One message may fail multiple times.
    failures: Int,
  )
}

fn calc_failure_score(state: State) -> Float {
  int.to_float(state.failures - state.successes)
  /. int.to_float(state.successes + state.failures)
}

fn create_progress_log(state: State, notice: String) -> String {
  notice
  <> int.to_string(state.successes)
  <> " successes, "
  <> int.to_string(state.failures)
  <> " failures, "
  <> state |> calc_failure_score |> float.to_string
  <> " failure score."
}

/// Processes messages recieved by the maw
fn handle_message(state: State, msg: Message) -> actor.Next(State, Message) {
  case msg {
    Queue(id, self) -> {
      case set.contains(state.active, id) {
        True -> actor.continue(state)
        False -> {
          let failure_score = calc_failure_score(state)
          case failure_score >. 0.6 {
            True -> {
              wisp.log_warning(
                "Skipping processing of "
                <> id
                <> " due to excessive errors (fs "
                <> float.to_string(failure_score)
                <> ")",
              )
              actor.continue(state)
            }
            False -> {
              spawn_email_worker(id, state.ctx, self)
              State(
                ..state,
                active: state.active |> set.insert(id),
                processing: state.processing + 1,
              )
              |> actor.continue
            }
          }
        }
      }
    }
    Finish(id) -> {
      create_progress_log(state, "Email processed: ")
      |> wisp.log_info
      State(
        ..state,
        active: state.active |> set.delete(id),
        successes: state.successes + 1,
        processing: state.processing - 1,
      )
      |> actor.continue
    }
    Restart(id, self) -> {
      spawn_email_worker(id, state.ctx, self)
      State(..state, failures: state.failures + 1)
      |> actor.continue
    }
    Abandon(id) -> {
      State(
        ..state,
        active: state.active |> set.delete(id),
        failures: state.failures + 1,
        processing: state.processing - 1,
      )
      |> actor.continue
    }
    Cancel(id) -> {
      State(
        ..state,
        active: state.active |> set.delete(id),
        processing: state.processing - 1,
      )
      |> actor.continue
    }
    Die -> {
      wisp.log_error("Terminating maw early")
      actor.stop()
    }
    GetStatus(reply) -> {
      QueueStatus(
        active: state.processing,
        successes: state.successes,
        failures: state.failures,
      )
      |> actor.send(reply, _)
      actor.continue(state)
    }
  }
}

/// Start a new mail manager, or return the existing one
fn start_mail_manager(
  ctx: APIContext,
  name: process.Name(Message),
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  case process.named(name) {
    Ok(pid) -> process.named_subject(name) |> actor.Started(pid, data: _) |> Ok
    Error(Nil) ->
      State(set.new(), ctx, 0, 0, 0)
      |> actor.new
      |> actor.named(name)
      |> actor.on_message(handle_message)
      |> actor.start
  }
}

/// Spawns an email worker and traps exits
fn spawn_email_worker(id: String, ctx: APIContext, manager: Subject(Message)) {
  // We don't want a crashed fetch to take down the entire program
  // So we start a new process and trap exits in it
  // The new process is because I don't see a clean way to make the actor
  // process listen for timeouts
  use <- process.spawn
  process.trap_exits(True)
  // The spawned process can't have args so we use a closure
  process.spawn(fn() { process_email(id, ctx, manager) })
  // Define a selector to trap exit messages
  process.new_selector()
  |> process.select_trapped_exits(fn(exit) {
    case exit {
      // A normal exit requires nothing of us
      process.ExitMessage(_, process.Normal) -> Nil
      // If the worker is killed then that's odd, log it and retry
      process.ExitMessage(_, process.Killed) -> {
        wisp.log_warning("Worker processing " <> id <> " killed, retrying")
        process.send(manager, Restart(id, manager))
      }
      // If the worker exists abnormally something has definitely gone wrong
      // We don't retry because we don't have any handling to limit retries
      // And we're in a weird state anyway
      process.ExitMessage(_, process.Abnormal(reason)) -> {
        wisp.log_error(
          "Worker processing "
          <> id
          <> "errored, retrying. Reason: "
          <> string.inspect(reason),
        )
      }
    }
  })
  |> process.selector_receive_forever
}

/// Middleware that asserts that an email hasn't been processed yet
/// Calls `if_done` if it has been processed, else `next`
fn check_not_processed(
  id: String,
  ctx: APIContext,
  if_done: fn() -> Nil,
  next: fn() -> Nil,
) -> Nil {
  case emails.select_email(id, ctx.db) {
    Some(email) -> {
      wisp.log_warning(
        "Email "
        <> id
        <> " has already been processed with success="
        <> bool.to_string(email.success),
      )
      if_done()
    }
    None -> next()
  }
}

/// Processes a single email
fn process_email(
  id: String,
  ctx: APIContext,
  manager: Subject(Message),
) -> Nil {
  use <- check_not_processed(id, ctx, fn() { process.send(manager, Cancel(id)) })
  case gmail.get_email(ctx.token, ctx.limiter, id) {
    Ok(resp) ->
      case parser.parse_email(resp) {
        Ok(#(updates, time)) -> {
          // Check another worker hasn't finished it
          // We shouldn't have simulatenous work, but lets be safe
          use <- check_not_processed(id, ctx, fn() {
            process.send(manager, Cancel(id))
          })
          // TODO: Do all database updates from this email in a single transaction
          // Save works and updates to the database
          case save_updates(ctx, updates, time) {
            Ok(_) ->
              // Mark this email as processed so we don't try it again in the future
              case emails.insert_email(id, True, ctx.db) {
                Ok(_) -> process.send(manager, Finish(id))
                Error(e) -> {
                  // If we've ended up here then the worst that might happen is that
                  // we might someday reprocess the email and duplicate the updates
                  wisp.log_warning(
                    "Unable to mark email as processed: " <> string.inspect(e),
                  )
                  process.send(manager, Finish(id))
                }
              }
            Error(e) -> {
              // Failure to save updates may be a temporary database issue
              // There's no harm in trying again
              wisp.log_warning("Unable to save updates: " <> string.inspect(e))
              process.send(manager, Restart(id, manager))
            }
          }
        }
        Error(e) -> {
          // If we can't parse the email then there's no point trying again
          case e {
            parser.ParseError(s) ->
              wisp.log_error("Unable to parse email:\n" <> s)
            parser.BuilderError(s) ->
              wisp.log_error("Unable to build email from parsed data: " <> s)
            parser.DecodeError(s) ->
              wisp.log_error(
                "Unable to decode email json: " <> string.inspect(s),
              )
          }
          process.send(manager, Abandon(id))
        }
      }
    Error(_) -> process.send(manager, Abandon(id))
  }
}

fn feed_maw(
  maw: Subject(Message),
  ctx: APIContext,
  page_id: Option(String),
) -> Nil {
  let msg_decoder = {
    use id <- decode.field("id", decode.string)
    id |> decode.success
  }

  let decoder = {
    use next_page <- decode.optional_field(
      "nextPageToken",
      None,
      decode.optional(decode.string),
    )
    use messages <- decode.field("messages", decode.list(msg_decoder))
    #(messages, next_page) |> decode.success
  }

  case gmail.get_email_list(ctx.token, ctx.limiter, ctx.label, page_id) {
    Ok(resp) ->
      case json.parse(resp, decoder) {
        Ok(#(messages, next_page)) -> {
          list.map(messages, fn(id) { process.send(maw, Queue(id, maw)) })
          case next_page {
            Some(next_page) -> feed_maw(maw, ctx, Some(next_page))
            None -> wisp.log_info("All pages processed")
          }
        }
        Error(e) ->
          wisp.log_error("Unable to parse message list: " <> string.inspect(e))
      }
    Error(e) ->
      wisp.log_error("Message list request failed: " <> string.inspect(e))
  }
}

fn save_updates(
  ctx: APIContext,
  updates: List(ArchiveUpdate),
  time: Timestamp,
) -> Result(Nil, sqlight.Error) {
  // Extract all works and write them to the database
  let work_query =
    updates
    |> list.map(fn(up) {
      case up.work {
        parser.SparseWork(..) -> None
        parser.DetailedWork(..) as w ->
          works.Work(
            w.id,
            w.title,
            w.authors,
            w.chapters,
            w.fandom,
            w.rating,
            w.warnings,
            w.series,
            w.summary,
          )
          |> Some
      }
    })
    |> option.values
    |> works.insert_works(ctx.db)

  use _ <- result.try(work_query)

  // Now that we've added works, we can add
  // the associated updates
  updates
  |> list.map(fn(up) {
    case up {
      parser.NewWork(work) ->
        update.PendingUpdate(work.id, None, "Work Created", None, time)
      parser.NewChapter(work, chapter_id, title, summary) ->
        update.PendingUpdate(work.id, Some(chapter_id), title, summary, time)
    }
  })
  |> update.insert_updates(ctx.db)
}
