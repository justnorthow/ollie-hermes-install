# Tests

Zero-dependency bash test harness for the install scripts' pure helpers
(bash + coreutils only — no bats, no other test framework).

## Running

```bash
bash tests/test-stack-env.sh
```

Each test file is a standalone bash script: it sources `tests/lib/assert.sh`,
sources the helper(s) under test from `scripts/lib/`, runs assertions, and
ends by calling `finish`. `finish` prints a `N/M passed` summary and returns
a shell exit status (0 = all passed, 1 = any failure), so a test file's own
exit code is meaningful in CI or when run directly.

## Harness API (`tests/lib/assert.sh`)

- `assert_eq DESC ACTUAL EXPECTED` — compares two strings; prints `ok:` or
  `FAIL:` with the expected/actual values.
- `assert_count DESC FILE KEY N` — counts lines in `FILE` matching `^KEY=`
  and asserts the count equals `N`.
- `finish` — prints the `passed/total` summary and exits non-zero if any
  assertion failed.

## Adding a new test file

1. Create `tests/test-<something>.sh`.
2. Source `tests/lib/assert.sh` and whatever helper(s) under `scripts/lib/`
   you're testing.
3. Write one or more `test_*` functions that call `assert_eq`/`assert_count`,
   then invoke them followed by `finish`.
4. Run it directly with `bash tests/test-<something>.sh`.

## Scope

These tests exercise pure, sourceable helpers only (e.g.
`scripts/lib/stack-env.sh`) — no docker, no network, no host mutation. The
install scripts themselves (`scripts/0N-*.sh`) are not run by this harness;
they require a real Linux host with Docker and are validated manually /
via `bash -n` syntax checks.
