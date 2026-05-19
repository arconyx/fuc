import fuc/env
import gleam/dict

pub fn load_env_test() {
  let assert Ok(env.Environment(vars)) = env.load_env("./test/data/test.env")
  assert dict.get(vars, "TEST_VARIABLE") == Ok("whoa")
  assert dict.get(vars, "SECOND_VARIABLE") == Ok("cat")
  assert dict.get(vars, "EMPTY_VAR") == Ok("")

  assert dict.get(vars, "MISSING_VAR") == Error(Nil)
}
