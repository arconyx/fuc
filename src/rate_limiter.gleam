//// Handle rate limiting in a bespoke and questionable fashion
////
//// Google rate limits us to 15000 quota units / user / second
//// Where getting the message list is 5 units and getting
//// and individual message is 5 units.
////
//// As we make requests we add their quota units to `intensity`
//// then reduce intensity by 15000 * minutes since last request
//// Negative intensities are rounded to zero.
////
//// As the intensity grows closer to 15000 we delay requests
//// more and more

import gleam/erlang/process.{type Name, type Subject}
import gleam/float
import gleam/int
import gleam/option.{type Option}
import gleam/otp/actor
import gleam/time/duration
import gleam/time/timestamp.{type Timestamp}

pub type Message {
  /// Add an element to the stack
  Poll(reply_with: Subject(Option(Int)), cost: Int)
}

/// Remove an element from the stack
type RateLimiter {
  RateLimiter(intensity: Float, last: Timestamp)
}

/// This function is called by the Actor each for each message it receives.
/// Actors are single threaded only does one thing at a time, so they handle
/// messages sequentially and one at a time, in the order they are received.
///
/// The function takes the message and the current state, and returns a data
/// structure that indicates what to do next, along with the new state.
fn handle_message(
  state: RateLimiter,
  msg: Message,
) -> actor.Next(RateLimiter, Message) {
  case msg {
    Poll(client, delta) -> {
      let delta = int.to_float(delta)

      // Get the seconds since the last request, min 0
      let now = timestamp.system_time()
      let time_delta =
        now
        |> timestamp.difference(state.last, _)
        |> duration.to_seconds
        |> float.max(0.0)

      // Calculate decay in intensity since last request 
      // 15000 / 60 = 250
      let decay = time_delta *. 250.0

      // Update intensity
      let intensity = { state.intensity -. decay +. delta } |> float.max(0.0)

      // Determine required sleep
      let threshold = 13_000.0
      case intensity >. threshold {
        // Sleep period is calculated as quota over threshold / (quota per millisecond)
        True -> {
          let delay =
            float.ceiling({ delta +. intensity -. threshold } /. 0.25)
            |> float.truncate
          process.send(client, option.Some(delay))
          let last = duration.milliseconds(delay) |> timestamp.add(now, _)
          actor.continue(RateLimiter(intensity, last))
        }
        False -> {
          process.send(client, option.None)
          actor.continue(RateLimiter(intensity, now))
        }
      }
    }
  }
}

/// Start rate limiting actor
pub fn start_rate_limiter(
  name: Name(Message),
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  actor.new(RateLimiter(0.0, timestamp.system_time()))
  |> actor.on_message(handle_message)
  |> actor.named(name)
  |> actor.start
}

/// Call a function, respecting the rate limiter
pub fn rate_limited(limiter: Name(Message), cost: Int, next: fn() -> res) -> res {
  let sleep = process.call(process.named_subject(limiter), 10, Poll(_, cost))
  case sleep {
    option.Some(delay) -> process.sleep(delay)
    option.None -> Nil
  }
  next()
}
