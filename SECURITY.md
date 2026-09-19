# Security policy

## Supported versions

The latest tagged version is supported.

## Reporting a vulnerability

Report a vulnerability through GitHub's private vulnerability reporting on this repository,
under its Security tab. Do not open a public issue. We acknowledge a report within three
working days and publish a fix before any disclosure.

## Evaluation of table content

Nothing in a row is evaluated. Arguments and expectations are passed to the command and to
the comparisons as literal strings, and the command name is executed as one word through
bats' `run`. The tests under `security:` in `tests/matrix.bats` check these properties.
