import fuc/database/oauth/tokens.{type OAuthToken}
import fuc/rate_limiter
import gleam/bool
import gleam/erlang/process.{type Name, type Subject}
import gleam/float
import gleam/hackney
import gleam/http
import gleam/http/request
import gleam/int
import gleam/option
import gleam/result
import gleam/string
import gleam/uri
import logging.{Error as LogError, Warning, log}

const base_path: String = "/gmail/v1/users/me/messages"

type FatalErrorVariant {
  BadRequest(response: String)
  Unauthorised(response: String)
  FatalRateLimit(response: String)
  InternalError(hackney.Error)
}

type TransientErrorVariant {
  // 403 variants
  RateLimitExceeded(response: String)
  UserRateLimitExceeded(response: String)
  // 429
  ToManyRequests(response: String)
  // 500, 502, 503 and 504 are grouped
  ServerError(response: String, code: Int)
  UnexpectedStatus(response: String, code: Int)
}

type InternalAPIError {
  TransientError(TransientErrorVariant)
  FatalError(FatalErrorVariant)
}

pub type Error {
  FatalAPIError
  AbortedByRateLimiter
  TooManyAttempts
  Timeout
}

fn new_request(
  token: OAuthToken,
  path: String,
  query: option.Option(String),
) -> request.Request(String) {
  request.Request(
    method: http.Get,
    headers: [#("authorization", "Bearer " <> token.access)],
    body: "",
    scheme: http.Https,
    host: "gmail.googleapis.com",
    port: option.None,
    path: path,
    query: query,
  )
}

// Send a request and parse the return status
fn send_request(
  req: request.Request(String),
) -> Result(String, InternalAPIError) {
  log(
    logging.Debug,
    "Sending a request to " <> { request.to_uri(req) |> uri.to_string() },
  )
  case hackney.send(req) {
    Ok(resp) ->
      case resp.status {
        // Status code handling based on descriptions at
        // https://developers.google.com/workspace/gmail/api/guides/handle-errors
        200 -> Ok(resp.body)
        400 -> BadRequest(resp.body) |> FatalError |> Error
        401 -> Unauthorised(resp.body) |> FatalError |> Error
        403 ->
          // Cheap out on the json parsing by doing simple string matching
          case
            string.contains(does: resp.body, contain: "userRateLimitExceeded")
          {
            True -> UserRateLimitExceeded(resp.body) |> TransientError |> Error
            False ->
              case
                string.contains(does: resp.body, contain: "rateLimitExceeded")
              {
                True -> RateLimitExceeded(resp.body) |> TransientError |> Error
                False -> FatalRateLimit(resp.body) |> FatalError |> Error
              }
          }
        // There's some special cases to 429 we're ignoring
        429 -> ToManyRequests(resp.body) |> TransientError |> Error
        500 | 502 | 503 | 504 ->
          ServerError(resp.body, code: resp.status) |> TransientError |> Error
        status -> UnexpectedStatus(resp.body, status) |> TransientError |> Error
      }
    // Hackney has an error type for invalid utf8 but it seems rare enough not to be worth
    // giving special retry handling, so we bundle it in with its generic fatal error
    Error(e) -> InternalError(e) |> FatalError |> Error
  }
}

fn rate_limited_with_retries(
  request: request.Request(String),
  limiter: Name(rate_limiter.Message),
  cost cost: Int,
  attempts max_attempts: Int,
) -> Result(String, Error) {
  do_rate_limited(
    process.named_subject(limiter),
    cost,
    max_attempts,
    request,
    0,
    // Google suggests 32 or 64 seconds
    64 * 1000,
  )
}

fn do_rate_limited(
  limiter: Subject(rate_limiter.Message),
  cost: Int,
  max_attempts: Int,
  request: request.Request(String),
  attempts: Int,
  max_backoff_ms: Int,
) -> Result(String, Error) {
  use <- bool.guard(attempts > max_attempts, Error(TooManyAttempts))

  case
    process.call(limiter, waiting: 5000, sending: fn(subject) {
      rate_limiter.Poll(subject, cost)
    })
  {
    rate_limiter.GoAhead ->
      case send_request(request) {
        Ok(resp) -> Ok(resp)
        Error(e) ->
          case e {
            TransientError(transient) -> {
              case transient {
                RateLimitExceeded(_) -> log(Warning, "403: Rate limit exceeded")
                UserRateLimitExceeded(_) ->
                  log(Warning, "403: User rate limit exceeded")
                ToManyRequests(_) -> log(Warning, "429: Too many requests")
                ServerError(_, code:) ->
                  log(Warning, int.to_string(code) <> ": Server error")
                UnexpectedStatus(_, code:) ->
                  log(
                    Warning,
                    int.to_string(code) <> ": Unexpected status code",
                  )
              }
              let base_backoff_time_ms =
                int.power(2, int.to_float(attempts))
                // if the exponent somehow fails approximate a fallback
                |> result.unwrap(int.to_float(4 * attempts))
                |> float.truncate()
              let backoff_jitter_ms =
                float.random() |> float.multiply(1000.0) |> float.truncate
              let backoff_ms = base_backoff_time_ms + backoff_jitter_ms

              use <- bool.guard(backoff_ms > max_backoff_ms, Error(Timeout))

              // We send the base backoff time so when we do next call it we should
              // be safely past it thanks to the jitter
              process.send(limiter, rate_limiter.Backoff(base_backoff_time_ms))
              process.sleep(backoff_ms)
              do_rate_limited(
                limiter,
                cost,
                max_attempts,
                request,
                attempts + 1,
                max_backoff_ms,
              )
            }
            FatalError(fatal) -> {
              case fatal {
                BadRequest(_) ->
                  log(LogError, "Gmail reports we sent a bad request.")
                Unauthorised(_) -> {
                  process.send(limiter, rate_limiter.BlockFutherRequests)
                  log(
                    LogError,
                    "Gmail reports we are unauthorised. Rate limiter instructed to refuse all requests.",
                  )
                }
                FatalRateLimit(_) ->
                  log(LogError, "Gmail reports we hit a fatal rate limit.")
                InternalError(_) ->
                  log(LogError, "Unexpected internal error when making request")
              }
              FatalAPIError |> Error
            }
          }
      }
    rate_limiter.TryAgain(after_ms:) -> {
      process.sleep(after_ms)
      do_rate_limited(
        limiter,
        cost,
        max_attempts,
        request,
        // Since it is just the rate limiter slowing us down don't count this as an attempt
        attempts,
        max_backoff_ms,
      )
    }
    rate_limiter.AbortForever -> AbortedByRateLimiter |> Error
  }
}

pub fn get_email(
  token: OAuthToken,
  rate_limiter: Name(rate_limiter.Message),
  id: String,
) -> Result(String, Error) {
  new_request(token, base_path <> "/" <> id, option.Some("format=full"))
  |> rate_limited_with_retries(rate_limiter, cost: 20, attempts: 12)
}

pub fn get_email_list(
  token: OAuthToken,
  rate_limiter: Name(rate_limiter.Message),
  label_id: String,
  page_id: option.Option(String),
) {
  let queries = [
    "q=from:do-not-reply%40archiveofourown.org",
    "includeSpamTrash=false",
    "labelIds=" <> label_id,
  ]
  let queries = case page_id {
    option.Some(token) -> ["pageToken=" <> token, ..queries]
    option.None -> queries
  }
  new_request(
    token,
    base_path,
    string.join(queries, with: "&")
      |> option.Some,
  )
  |> rate_limited_with_retries(rate_limiter, cost: 5, attempts: 12)
}
