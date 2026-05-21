import envoy
import fuc/file
import gleam/bool
import gleam/dict
import gleam/list
import gleam/result
import gleam/string
import logging

pub type Environment {
  Environment(dict.Dict(String, String))
}

// Read the value for the given key from the environment object,
// falling back to the process environment variables.
pub fn get(environment: Environment, key: String) -> Result(String, Nil) {
  let Environment(env_dict) = environment
  case dict.get(env_dict, key) {
    Ok(value) -> Ok(value)
    Error(_) -> envoy.get(key)
  }
}

/// Load environment from an env file formated with
/// KEY=VALUE lines. Values may be double quoted.
/// 
/// TODO: Use a more structured format with proper parsing - JSON?
pub fn load_env(from: String) -> Result(Environment, Nil) {
  case file.read(from) {
    Ok(envstr) ->
      string.split(envstr, "\n")
      |> list.map(string.trim)
      |> list.filter(fn(line) {
        line != "" && bool.negate(string.starts_with(line, "#"))
      })
      |> list.try_map(extract_key_and_value_from_line)
      |> result.map(fn(list) {
        dict.from_list(list)
        |> Environment
      })
    Error(_) -> Error(Nil)
  }
}

pub fn load_env_from_systemd() -> Environment {
  case envoy.get("CREDENTIALS_DIRECTORY") {
    Ok(dir) -> {
      let file = dir <> "/fuc.env"
      case load_env(file) {
        Ok(env) -> {
          logging.log(logging.Info, "Loaded credentials file from " <> file)
          Ok(env)
        }
        Error(_) -> {
          logging.log(
            logging.Error,
            "Unable to read credentials file from "
              <> file
              <> ", falling back to environment variables",
          )
          Error(Nil)
        }
      }
    }
    Error(Nil) -> {
      logging.log(
        logging.Info,
        "$CREDENTIALS_DIRECTORY not found, falling back to environment variables",
      )
      Error(Nil)
    }
  }
  |> result.lazy_unwrap(fn() { Environment(dict.new()) })
}

fn extract_key_and_value_from_line(
  line: String,
) -> Result(#(String, String), Nil) {
  use #(key, value) <- result.try(string.split_once(line, "="))

  let key = string.trim(key)
  let value = string.trim(value) |> unquote_value

  case string.is_empty(key) {
    True -> Nil |> Error
    False -> #(key, value) |> Ok
  }
}

/// Strip double quotes from values
fn unquote_value(value: String) -> String {
  case string.starts_with(value, "\"") && string.ends_with(value, "\"") {
    True -> string.remove_prefix(value, "\"") |> string.remove_suffix("\"")
    False -> value
  }
}
