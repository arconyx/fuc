import gleam/bit_array

/// Open and read a UTF-8 encoded file at the given path
pub fn read(filepath: String) -> Result(String, Nil) {
  case read_bits(filepath) {
    Ok(binary) ->
      case bit_array.to_string(binary) {
        Ok(str) -> Ok(str)
        Error(_) -> Error(Nil)
      }
    Error(_) -> Error(Nil)
  }
}

@external(erlang, "fuc_ffi", "read_file")
fn read_bits(filepath: String) -> Result(BitArray, Nil)
