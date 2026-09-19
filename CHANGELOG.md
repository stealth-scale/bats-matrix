# Changelog

Every change a user would notice is recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-09-19

First tagged release.

### Added

- `run_matrix COMMAND [DELIMITER]`: runs a command against a table of rows read from stdin,
  each row holding arguments, an expected exit status and an expected output.
- Output modes: substring, `EMPTY`, `~ regex` and `\n` multiline.
- `BATS_MATRIX_DELIMITER` and the delimiter argument.
- `MATRIX_DEBUG` to print every row before it runs.
- A failure report with the row, the command, the expectation and the actual value.
- `load.bash` as the entry point for `load` and `bats_load_library`.
- A test suite of 155 cases, including strict-mode, input validation and EOF regressions.
- Container tests with Podman and Docker on Bash 4.4, 5.1, 5.2 and 5.3 with bats-core
  1.7.0 and 1.14.0, plus host tests on Ubuntu and macOS.

### Fixed

- Validation errors (a missing command name, a malformed row, a non-integer status) now stop
  the run instead of continuing after the message.
- Trimming no longer leaves `LC_ALL=C` set in the calling shell, so the command under test
  and later assertions run in the caller's locale.
- A row that expects exit status 127 runs through `run -127`, so bats does not raise
  warning BW01 for it.
- The delimiter is quoted when the row is rebuilt for the failure report.
- Exit statuses are validated as decimal values from 0 to 255, with leading zeroes
  normalized without octal interpretation or arithmetic evaluation.
- Ambiguous delimiters and malformed regexes are rejected; an invalid regex does not
  execute the affected row's command.
- An unterminated final row is processed, and commands cannot consume subsequent rows
  from the table's stdin.
- Failure reports include the source row number and quote arguments unambiguously.

[Unreleased]: https://github.com/stealth-scale/bats-matrix/compare/v1.0.0...main
[1.0.0]: https://github.com/stealth-scale/bats-matrix/releases/tag/v1.0.0
