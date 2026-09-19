# bats-matrix

Table-driven tests for [bats-core](https://github.com/bats-core/bats-core). One `@test` runs
one command against a table of rows. Each row lists the arguments, the exit status you expect
and the output you expect.

```bash
@test "slugify" {
    run_matrix slugify <<'EOM'
        # input        | status | output
        Hello World    | 0      | hello-world
        Hello  World   | 0      | ~ ^hello-+world$
                       | 1      | EMPTY
EOM
}
```

The runner executes every row through bats' `run`, checks the status, then checks the output.
The first row that fails ends the test with a report. The report shows the row, the command as
it was called, the expectation and the actual value.

## Install

Add the repository as a submodule next to your tests and load it:

```sh
git submodule add https://github.com/stealth-scale/bats-matrix tests/helpers/bats-matrix
```

```bash
load 'helpers/bats-matrix/load'
```

`load.bash` is the entry point, so `bats_load_library bats-matrix` works as well when the
repository is on `BATS_LIB_PATH`. `make install` copies the library to
`/usr/local/lib/bats-matrix` for a system-wide `load`.

Requirements: Bash 4 or later and bats-core 1.5.0 or later. The runner refuses to load on
Bash 3. CI tests Bash 4.4, 5.1, 5.2 and 5.3 with bats-core 1.7.0 and 1.14.0, plus host
runs on Ubuntu and macOS.

## Writing a table

`run_matrix COMMAND [DELIMITER]` reads the table from standard input. A row is:

```
arg1 | arg2 | ... | status | output
```

- The last two columns are the expected exit status and the expected output. Every column
  before them is an argument. A row with two columns runs the command without arguments.
- Whitespace around a column is trimmed. An empty column is an empty argument.
- Blank lines and lines starting with `#` are skipped.
- Nothing in a row is evaluated by the shell. `$(...)`, backticks, quotes and globs are passed
  to the command as literal text.
- The command runs with its standard input on `/dev/null`, so a command that reads stdin does
  not consume the rows after it.
- `status` must be a decimal integer from 0 to 255; leading zeroes are accepted. An invalid
  status stops the run before that row executes. Earlier rows may already have run.

## Expecting output

The output column has four modes. The first characters of the column select the mode.

| Column                  | Mode      | Passes when                                                                       |
| ----------------------- | --------- | --------------------------------------------------------------------------------- |
| `text`                  | substring | the output contains `text`. Newlines and carriage returns are removed first, so `text` may span two lines |
| `EMPTY` or empty        | empty     | the command printed nothing                                                       |
| `~ regex`               | regex     | the output, with trailing whitespace trimmed, matches the extended regex. `^` and `$` anchor the whole output, not a line |
| `text\nmore`            | multiline | the output contains the block verbatim once `\n` and `\t` are expanded             |

The substring and multiline modes match literal text: `[`, `*` and `?` are characters, not
patterns. Matching is case sensitive.

## Delimiters

The default delimiter is `|`. A delimiter must be one non-whitespace character. Pass another
one as the second argument when a value or a regex needs the pipe:

```bash
run_matrix printf ';' <<'EOM'
    %s ; a|b ; 0 ; ~ ^a\|b$
EOM
```

`BATS_MATRIX_DELIMITER` sets the default for a whole file. When both are given, the argument
is used. The parser sets `IFS` for one `read` only, so the command runs with the default `IFS`.

## The failure report

```
# ================================================================================
#   ✖ MATRIX TEST FAILED: Output Mismatch
# ================================================================================
#   Context:
#     Input Row   : Foo Bar
#     Command     : slugify 'Foo Bar'
#
#   Assertion:
#     Expected    : Output to contain 'foo_bar'
#     Actual      : foo-bar
# ================================================================================
```

The failure types are `Status Mismatch`, `Output Mismatch`, `Unexpected Output`,
`Regex Mismatch` and `Multiline Mismatch`. A status mismatch appends the command's output
under `Output Log`. A multiline mismatch appends the block it looked for under
`Missing Block`.

`run_matrix` returns 0 when every row passed and 1 otherwise, so it fails a test on its own
under bats' errexit. After it returns, `$status` and `$output` hold the last row that ran.

Set `MATRIX_DEBUG=1` to print every row to stderr before it runs:

```
DEBUG: run_matrix -> args:[Hello World] status:[0] expect:[hello-world]
```

## Limits

- A first argument cannot start with `#`. The row reads as a comment.
- The literal text `EMPTY` cannot be asserted. The word is the keyword for no output.
- A trailing delimiter adds an empty last column, which shifts the status column and is
  rejected.
- A row that expects exit status 127 runs through `run -127`, so bats does not raise warning
  BW01 for it. Any other row that hits 127 does raise it, which is what you want for a
  misspelt command.

## Reference

| Name                                   | What it is                                                              |
| -------------------------------------- | ----------------------------------------------------------------------- |
| `run_matrix COMMAND [DELIMITER]`       | Runs the table on stdin. Returns 0 when every row passed, 1 otherwise   |
| `matrix::runner::execute`              | The same function under its namespaced name                             |
| `BATS_MATRIX_DELIMITER`                | The default delimiter. `\|` unless set before the library is loaded      |
| `MATRIX_DEBUG`                         | When non-empty, prints every row to stderr before it runs               |
| `matrix::internal::require_bash4 [N]`  | Fails when the major version `N`, or the running shell's, is under 4    |

`fail` comes from bats-support when it is loaded, and from a polyfill that prints to stderr
and returns 1 when it is not.

## Working here

```sh
make test                                   # the suite in the test image: bash 5.2, bats 1.14.0
make test BASH_VERSION=4.4 BATS_VERSION=1.7.0
make test-host                              # the suite with the bash and bats of this machine
make lint                                   # shellcheck over the loader, the sources and the tests
make check                                  # what CI runs: lint, then test
```

`RUNTIME=docker` selects Docker. The default is Podman. `TARGET` selects one test file.

[CONTRIBUTING.md](CONTRIBUTING.md) has the rest.

## License

[MIT](LICENSE). Copyright Stealth Scale B.V.
