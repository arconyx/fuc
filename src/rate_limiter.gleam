//// Handle rate limiting in a bespoke and questionable fashion
////
//// Google rate limits us to 6000 quota units / user / minute
//// Where getting the message list is 5 units and getting
//// an individual message is 5 units.
////
//// As we make requests we add their quota units to `intensity`
//// then reduce intensity by 6000 * minutes since last request
//// Negative intensities are rounded to zero.
////
//// As the intensity grows closer to 6000 we delay requests
//// more and more

import gleam/bool
import gleam/erlang/process.{type Name, type Subject}
import gleam/float
import gleam/int
import gleam/option.{type Option}
import gleam/order
import gleam/otp/actor
import gleam/time/duration
import gleam/time/timestamp.{type Timestamp}

pub type Message {
  /// Add an element to the stack
  Poll(caller: Subject(LimiterResponse), cost: Int)
  Backoff(for_ms: Int)
  BlockFutherRequests
}

pub type LimiterResponse {
  GoAhead
  TryAgain(after_ms: Int)
  AbortForever
}

/// Remove an element from the stack
type RateLimiter {
  RateLimiter(
    // The quota is allowed to go negative
    quota: Int,
    max_quota: Int,
    restore_quantity: Int,
    restore_period: duration.Duration,
    last_restore: Timestamp,
    backoff_until: Option(Timestamp),
    block_future_requests: Bool,
  )
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
    Poll(caller:, cost:) -> {
      let #(new_state, msg) = query_limiter(state, cost)
      process.send(caller, msg)
      actor.continue(new_state)
    }

    Backoff(for_ms) -> {
      let until =
        timestamp.system_time() |> timestamp.add(duration.milliseconds(for_ms))
      case state.backoff_until {
        option.Some(current) ->
          case timestamp.compare(until, current) {
            order.Lt | order.Eq -> actor.continue(state)
            order.Gt ->
              RateLimiter(..state, backoff_until: option.Some(until))
              |> actor.continue()
          }
        option.None ->
          RateLimiter(..state, backoff_until: option.Some(until))
          |> actor.continue()
      }
    }
    BlockFutherRequests ->
      RateLimiter(..state, block_future_requests: True) |> actor.continue()
  }
}

/// Start rate limiting actor
pub fn start_rate_limiter(
  name: Name(Message),
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  actor.new(RateLimiter(
    quota: 0,
    // We are limited to 6000/req/user/minute but we use a shorter
    // restore period and proportional rate to reduce burstiness
    max_quota: 6000,
    restore_quantity: 100,
    restore_period: duration.seconds(1),
    last_restore: timestamp.from_unix_seconds(0),
    backoff_until: option.None,
    block_future_requests: False,
  ))
  |> actor.on_message(handle_message)
  |> actor.named(name)
  |> actor.start
}

/// Call a function, respecting the rate limiter
pub fn rate_limited(
  limiter: Name(Message),
  cost: Int,
  next: fn() -> res,
) -> res {
  let sleep = process.call(process.named_subject(limiter), 10, Poll(_, cost))
  case sleep {
    option.Some(delay) -> process.sleep(delay)
    option.None -> Nil
  }
  next()
}

/// Calculate the amount of quota freed up over a time period.
fn restore_quota(limiter: RateLimiter, at: Timestamp) -> RateLimiter {
  // TODO: Use monotonic clock
  let time_since_last_restore = timestamp.difference(limiter.last_restore, at)

  case duration.compare(time_since_last_restore, limiter.restore_period) {
    order.Lt -> limiter
    order.Eq | order.Gt -> {
      let seconds_since_last_restore =
        duration.to_seconds(time_since_last_restore)
      let restore_period_seconds = duration.to_seconds(limiter.restore_period)
      let complete_periods =
        float.truncate(seconds_since_last_restore /. restore_period_seconds)
      RateLimiter(
        ..limiter,
        quota: int.min(
          limiter.quota + { limiter.restore_quantity * complete_periods },
          limiter.max_quota,
        ),
        last_restore: at,
      )
    }
  }
}

fn add_jitter(base: Float, max_jitter_decimal_percent: Float) -> Float {
  let jitter_percent = float.random() *. max_jitter_decimal_percent
  base *. { 1.0 +. jitter_percent }
}

/// Convert a duration to ms with jitter and a min bound
fn duration_to_delay_ms(
  duration: duration.Duration,
  jitter_percent: Float,
) -> Int {
  duration
  |> duration.to_seconds
  |> float.min(0.0)
  |> add_jitter(jitter_percent)
  // to milliseconds
  |> float.multiply(1000.0)
  |> float.ceiling
  |> float.truncate
}

fn query_limiter(
  limiter: RateLimiter,
  cost: Int,
) -> #(RateLimiter, LimiterResponse) {
  use <- bool.guard(limiter.block_future_requests, #(limiter, AbortForever))

  let cost = int.absolute_value(cost)
  let now = timestamp.system_time()

  case limiter.backoff_until {
    option.Some(wait_until) ->
      case timestamp.compare(now, wait_until) {
        // If we haven't reached the backoff endpoint
        // Then reject the request with a suggested retry
        // period
        order.Lt -> {
          let suggested_delay =
            timestamp.difference(now, wait_until)
            |> duration_to_delay_ms(0.1)

          #(limiter, TryAgain(suggested_delay))
        }
        // If we're right at the point we resume again sleep a touch more
        // for good measure
        order.Eq -> #(
          limiter,
          // 250-750ms
          add_jitter(250.0, 1.0) |> float.truncate |> TryAgain,
        )
        // If the backoff is over then clear it and call the function again.
        // This was the easiest than making this path directly call the same
        // code as the outer `option.None` branch.
        order.Gt ->
          query_limiter(
            RateLimiter(..limiter, backoff_until: option.None),
            cost,
          )
      }
    option.None -> {
      let limiter = restore_quota(limiter, now)
      case int.compare(cost, limiter.quota) {
        // If we have capacity update it and approve the query
        order.Lt | order.Eq -> #(
          RateLimiter(..limiter, quota: limiter.quota - cost),
          GoAhead,
        )
        // No capacity left. Suggest waiting for the next refresh
        order.Gt -> {
          let next_restore =
            timestamp.add(limiter.last_restore, limiter.restore_period)
          let suggested_delay =
            timestamp.difference(now, next_restore)
            |> duration_to_delay_ms(0.1)
          #(limiter, TryAgain(suggested_delay))
        }
      }
    }
  }
}
