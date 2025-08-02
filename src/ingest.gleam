import gleam/bool
import gleam/erlang/process.{type Name, type Subject}
import gleam/hackney
import gleam/http
import gleam/http/request
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/set.{type Set}
import gleam/string
import rate_limiter
import sqlight
import wisp

import state.{type Context, type OAuthToken}

pub type MessageID =
  String

pub type Message {
  /// Queue an email for processing
  Queue(id: MessageID, manager: Subject(Message))
  /// Mark an email as processed
  Finish(id: MessageID)
  /// Start a new worker for an email
  Restart(id: MessageID, manager: Subject(Message))
}

type APIContext {
  APIContext(
    db: sqlight.Connection,
    label: String,
    limiter: Name(rate_limiter.Message),
    token: OAuthToken,
  )
}

type MawState {
  MawState(active: Set(MessageID), ctx: APIContext)
}

/// This function is called by the Actor each for each message it receives.
/// Actors are single threaded only does one thing at a time, so they handle
/// messages sequentially and one at a time, in the order they are received.
///
/// The function takes the message and the current state, and returns a data
/// structure that indicates what to do next, along with the new state.
fn handle_message(
  stomach: MawState,
  msg: Message,
) -> actor.Next(MawState, Message) {
  case msg {
    Queue(id, self) -> {
      case set.contains(stomach.active, id) {
        True -> actor.continue(stomach)
        False -> {
          spawn_email_worker(id, stomach.ctx, self)
          actor.continue(
            MawState(..stomach, active: stomach.active |> set.insert(id)),
          )
        }
      }
    }
    Finish(id) -> {
      actor.continue(
        MawState(..stomach, active: stomach.active |> set.delete(id)),
      )
    }
    Restart(id, self) -> {
      spawn_email_worker(id, stomach.ctx, self)
      actor.continue(stomach)
    }
  }
}

pub fn start_mail_manager(ctx: Context, token: OAuthToken) {
  APIContext(ctx.database_connection, ctx.ao3_label, ctx.rate_limiter, token)
  |> MawState(set.new(), _)
  |> actor.new
  |> actor.on_message(handle_message)
  |> actor.start
}

/// Spawns an email worker and traps exits
fn spawn_email_worker(id: MessageID, ctx: APIContext, manager: Subject(Message)) {
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
fn check_not_processed(id: MessageID, ctx: APIContext, next: fn() -> Nil) -> Nil {
  case state.select_email(id, ctx.db) {
    Some(email) -> {
      wisp.log_warning(
        "Email "
        <> id
        <> " has already been processed with success="
        <> bool.to_string(email.success),
      )
    }
    None -> next()
  }
}

/// Processes a single email
fn process_email(
  id: MessageID,
  ctx: APIContext,
  manager: Subject(Message),
) -> Nil {
  use <- check_not_processed(id, ctx)
  let url =
    "https://gmail.googleapis.com/gmail/v1/users/me/messages/"
    <> id
    <> "?format=full"
  case request.to(url) {
    Error(_) -> {
      wisp.log_error("Unable to construct request from url (aborting): " <> url)
    }
    Ok(req) -> {
      let req =
        req
        |> request.set_method(http.Get)
        |> request.set_header("authorization", "Bearer " <> ctx.token.access)
      case hackney.send(req) {
        Error(e) -> {
          wisp.log_warning(
            "Request for message "
            <> id
            <> "failed with error: "
            <> string.inspect(e),
          )
          process.sleep(10 * 1000)
          process.send(manager, Restart(id, manager))
        }
        Ok(resp) -> {
          parse_email()
          // Check another worker hasn't finished it
          // We shouldn't have simulatenous work, but lets be safe
          use <- check_not_processed(id, ctx)
          // TODO: Do all database updates from this email in a single transaction
          case state.insert_email(id, True, ctx.db) {
            Ok(_) -> Nil
            Error(e) ->
              wisp.log_error(
                "Unable to mark email as processed: " <> string.inspect(e),
              )
          }
          process.send(manager, Finish(id))
        }
      }
      Nil
    }
  }
}

fn parse_email() {
  todo
}
