#!/usr/bin/env bash
# Minimal zero-dependency test asserts. Source this, call asserts, end with finish.
_tests=0; _fails=0
assert_eq() { # DESC ACTUAL EXPECTED
  _tests=$((_tests+1))
  if [ "$2" = "$3" ]; then echo "  ok: $1"
  else echo "  FAIL: $1"; echo "    expected: [$3]"; echo "    actual:   [$2]"; _fails=$((_fails+1)); fi
}
assert_count() { # DESC FILE KEY EXPECTED_COUNT  (counts lines matching ^KEY=)
  local n; n="$(grep -Ec "^$3=" "$2" || true)"
  assert_eq "$1" "$n" "$4"
}
assert_nonempty() { # DESC VALUE
  _tests=$((_tests+1))
  if [ -n "$2" ]; then echo "  ok: $1"
  else echo "  FAIL: $1"; echo "    expected: [non-empty]"; echo "    actual:   []"; _fails=$((_fails+1)); fi
}
assert_file_exists() { # DESC PATH
  _tests=$((_tests+1))
  if [ -f "$2" ]; then echo "  ok: $1"
  else echo "  FAIL: $1"; echo "    expected: [file exists]"; echo "    actual:   [missing: $2]"; _fails=$((_fails+1)); fi
}
finish() { echo; echo "$((_tests-_fails))/$_tests passed"; [ "$_fails" -eq 0 ]; }
