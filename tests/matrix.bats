#!/usr/bin/env bats

# ==============================================================================
# BATS Matrix Runner - Comprehensive Test Suite
# ==============================================================================
# Organized into the following groups:
#   01. Core Execution (Rows, Return Codes, Bare Commands)
#   02. Row Parsing - Basic (Trimming, Empty Fields, Blank Lines, Comments)
#   03. Row Parsing - Advanced (Special Chars, Unicode, Quotes, CRLF, Pipes, EOF)
#   04. Delimiters (Argument, Environment, Precedence)
#   05. Output Assertions - Substring (Default Mode)
#   06. Output Assertions - EMPTY
#   07. Output Assertions - Regex (~)
#   08. Output Assertions - Multiline (\n)
#   09. Status Assertions (Boundaries, Decimal Values, Leading Zeros)
#   10. Failure Reporting & Feedback
#   11. Strict Mode & Compliance (errexit, nounset, IFS, Locale, Globals)
#   12. Interactions (Functions, Binaries, Builtins, Stdin, Nested run)
#   13. Configuration & Debugging (MATRIX_DEBUG)
#   14. Security & Safety (No Evaluation of Rows or Names)
#   15. Error Handling (Invalid Rows, Missing Input, Missing Command)
#   16. Environment Guards (Bash Version, Dependencies, fail Polyfill, Load)
#   17. Internal API (Whitebox)
#   18. Scale (Many Rows, Wide Rows, Huge Payloads)
# ==============================================================================

setup() {
    # Enforce Strict Mode for Tests
    set -Euoe pipefail

    # We check return codes on the run function
    bats_require_minimum_version 1.5.0

    # Robust Library Loading
    local lib_dir="$BATS_TEST_DIRNAME/../src"

    if [ -f "$lib_dir/matrix.bash" ]; then
        load "$lib_dir/matrix.bash"
    # Fallback to current dir if testing in-place
    elif [ -f "$BATS_TEST_DIRNAME/matrix.bash" ]; then
        load "$BATS_TEST_DIRNAME/matrix.bash"
    else
        echo "Error: Could not find matrix.bash in '$BATS_TEST_DIRNAME' or '$lib_dir'" >&2
        return 1
    fi
}

# ------------------------------------------------------------------------------
# Fixtures: the commands the matrix runs against. They are not the subject.
# ------------------------------------------------------------------------------

# Prints every argument in brackets, so trimming and empty fields are visible.
brackets() { printf '[%s]' "$@"; }

# Two lines of output, for the multiline and regex anchoring cases.
two_lines() { printf 'line one\nline two\n'; }

# Output with Windows line endings.
crlf_lines() { printf 'alpha\r\nbeta\r\n'; }

# Output with trailing spaces.
padded() { printf 'value   \n'; }

# Output with a tab and a second line.
tabbed() { printf 'a\tb\nc\n'; }

# Output containing the default delimiter.
piped() { printf 'a|b\n'; }

# Returns the status it is given.
exit_with() { return "${1:-0}"; }

# Output plus a non-zero status.
noisy_fail() { echo "boom happened"; return 3; }

# Joins an array with the first character of IFS, which exposes a leaked IFS.
join_ifs() { local x=(1 2 3); echo "${x[*]}"; }

# Records one line per call, to count executions.
record() { echo "called $*" >> "${BATS_TEST_TMPDIR}/calls"; }

# A command that uses bats' run itself.
uses_run() { run false; echo "inner status ${status}"; }

# Removes bats' run inside the subshell that the outer run provides.
without_run() { unset -f run; run_matrix brackets <<< "a | 0 | [a]"; }

# ==============================================================================
# GROUP 01: CORE EXECUTION
# ==============================================================================

@test "core: single row -> passes and returns 0" {
    run run_matrix brackets <<'EOM'
        a | 0 | [a]
EOM
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "core: multiple rows -> every row is executed in order" {
    run_matrix record <<'EOM'
        first  | 0 | EMPTY
        second | 0 | EMPTY
        third  | 0 | EMPTY
EOM
    run cat "${BATS_TEST_TMPDIR}/calls"
    [ "${lines[0]}" = "called first" ]
    [ "${lines[1]}" = "called second" ]
    [ "${lines[2]}" = "called third" ]
    [ "${#lines[@]}" -eq 3 ]
}

@test "core: multiple arguments -> passed in column order" {
    run_matrix brackets <<'EOM'
        a | b | c | 0 | [a][b][c]
EOM
}

@test "core: no arguments -> runs the bare command" {
    run_matrix true <<'EOM'
        0 | EMPTY
EOM
}

@test "core: no arguments -> bare command output is asserted" {
    run_matrix two_lines <<'EOM'
        0 | line one
EOM
}

@test "core: first failing row -> stops the matrix, later rows do not run" {
    run run_matrix record <<'EOM'
        first  | 1 | EMPTY
        second | 0 | EMPTY
EOM
    [ "$status" -eq 1 ]
    run cat "${BATS_TEST_TMPDIR}/calls"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
    [ "${lines[0]}" = "called first" ]
}

@test "core: later failure -> earlier rows run, rows after the failure do not" {
    run run_matrix record <<'EOM'
        first  | 0 | EMPTY
        second | 1 | EMPTY
        third  | 0 | EMPTY
EOM
    [ "$status" -eq 1 ]
    [[ "$output" == *"Status Mismatch"* ]]
    run cat "${BATS_TEST_TMPDIR}/calls"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [ "${lines[0]}" = "called first" ]
    [ "${lines[1]}" = "called second" ]
}

@test "core: repeat -> two matrices in one test do not share state" {
    run_matrix brackets <<'EOM'
        a | 0 | [a]
EOM
    run_matrix brackets <<'EOM'
        b | 0 | [b]
EOM
    [ "$output" = "[b]" ]
}

@test "core: alias -> run_matrix and matrix::runner::execute behave the same" {
    matrix::runner::execute brackets <<'EOM'
        a | 0 | [a]
EOM
    run matrix::runner::execute brackets <<'EOM'
        a | 0 | [b]
EOM
    [ "$status" -eq 1 ]
    [[ "$output" == *"Output Mismatch"* ]]
}

# ==============================================================================
# GROUP 02: ROW PARSING - BASIC
# ==============================================================================

@test "parse: trimming -> surrounding whitespace is removed from every column" {
    run_matrix brackets <<'EOM'
          a   |    b  |  0  |   [a][b]
EOM
}

@test "parse: empty field -> kept as an empty argument" {
    run_matrix brackets <<'EOM'
        a |   | 0 | [a][]
EOM
}

@test "parse: empty first field -> kept as an empty argument" {
    run_matrix brackets <<'EOM'
          | b | 0 | [][b]
EOM
}

@test "parse: adjacent empty fields -> each field remains a separate argument" {
    run_matrix brackets <<'EOM'
        | | middle | | 0 | [][][middle][]
EOM
    [ "$output" = "[][][middle][]" ]
}

@test "parse: blank lines -> skipped" {
    run_matrix brackets <<'EOM'

        a | 0 | [a]

        b | 0 | [b]

EOM
}

@test "parse: comments -> lines starting with # are skipped" {
    run_matrix brackets <<'EOM'
        # a comment
            # an indented comment
        a | 0 | [a]
EOM
}

@test "parse: comments -> documents that a first argument cannot start with #" {
    run run_matrix brackets <<'EOM'
        #tag | 0 | [#tag]
EOM
    [ "$status" -eq 1 ]
    [[ "$output" == *"no valid input lines"* ]]
}

@test "parse: empty expectation -> an empty last column means EMPTY" {
    run_matrix true <<'EOM'
        0 |
EOM
}

@test "parse: indentation -> tabs before a row are trimmed" {
    run_matrix brackets < <(printf '\t\ta | 0 | [a]\n')
}

# ==============================================================================
# GROUP 03: ROW PARSING - ADVANCED
# ==============================================================================

@test "parse: spaces inside an argument -> preserved as one argument" {
    run_matrix brackets <<'EOM'
        hello world | 0 | [hello world]
EOM
}

@test "parse: flags -> hyphens are passed through" {
    run_matrix brackets <<'EOM'
        -la | --long=1 | 0 | [-la][--long=1]
EOM
}

@test "parse: paths -> slashes are passed through" {
    run_matrix brackets <<'EOM'
        /usr/local/bin | 0 | [/usr/local/bin]
EOM
}

@test "parse: quotes -> quote characters are literal, not shell syntax" {
    run_matrix brackets <<'EOM'
        'single' | "double" | 0 | ['single']["double"]
EOM
}

@test "parse: glob characters -> not expanded" {
    run_matrix brackets <<'EOM'
        * | ? | 0 | [*][?]
EOM
}

@test "parse: unicode -> utf-8 arguments are passed through" {
    run_matrix brackets <<'EOM'
        café | 0 | [café]
EOM
}

@test "parse: emoji -> passed through" {
    run_matrix brackets <<'EOM'
        🚀 | 0 | [🚀]
EOM
}

@test "parse: backslashes -> literal in arguments" {
    run_matrix brackets <<'EOM'
        C:\temp | 0 | [C:\temp]
EOM
}

@test "parse: CRLF rows -> carriage returns are trimmed" {
    run_matrix brackets < <(printf 'a | 0 | [a]\r\nb | 0 | [b]\r\n')
}

@test "parse: piped input -> rows can come from a pipe instead of a heredoc" {
    printf 'a | 0 | [a]\nb | 0 | [b]\n' | run_matrix brackets
}

@test "parse: here-string -> rows can come from a here-string" {
    run_matrix brackets <<< "a | 0 | [a]"
}

@test "parse: EOF -> a single row without a final newline is executed" {
    run_matrix record < <(printf '%s' 'last | 0 | EMPTY')
    run cat "${BATS_TEST_TMPDIR}/calls"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
    [ "${lines[0]}" = "called last" ]
}

@test "parse: EOF -> a failing final row without a newline fails the matrix" {
    run run_matrix brackets < <(printf '%s' $'first | 0 | [first]\nlast | 0 | [wrong]')
    [ "$status" -eq 1 ]
    [[ "$output" == *"Output Mismatch"* ]]
    [[ "$output" == *"Actual      : [last]"* ]]
}

@test "parse: EOF -> an empty last column is preserved without a final newline" {
    run_matrix record < <(printf '%s' 'last | 0 |')
    run cat "${BATS_TEST_TMPDIR}/calls"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
    [ "${lines[0]}" = "called last" ]
}

@test "parse: EOF -> an unterminated comment does not add a call" {
    run_matrix record < <(printf '%s' $'first | 0 | EMPTY\n# last comment')
    run cat "${BATS_TEST_TMPDIR}/calls"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
    [ "${lines[0]}" = "called first" ]
}

@test "parse: EOF -> unterminated trailing whitespace does not add a call" {
    run_matrix record < <(printf '%s' $'first | 0 | EMPTY\n \t ')
    run cat "${BATS_TEST_TMPDIR}/calls"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
    [ "${lines[0]}" = "called first" ]
}

@test "parse: trailing delimiter -> documents that it shifts the columns and is rejected" {
    run run_matrix brackets <<'EOM'
        a | 0 | [a] |
EOM
    [ "$status" -eq 1 ]
    [[ "$output" == *"must be a decimal integer from 0 to 255"* ]]
}

# ==============================================================================
# GROUP 04: DELIMITERS
# ==============================================================================

@test "delimiter: default -> pipe, set when the file is sourced" {
    # shellcheck disable=SC2016  # the script runs in the child bash
    run env -u BATS_MATRIX_DELIMITER bash -c 'source "$1"; printf "%s" "$BATS_MATRIX_DELIMITER"' \
        _ "$BATS_TEST_DIRNAME/../src/matrix.bash"
    [ "$status" -eq 0 ]
    [ "$output" = "|" ]
}

@test "delimiter: argument -> second argument overrides the delimiter" {
    run_matrix brackets ';' <<'EOM'
        a;b;0;[a][b]
EOM
}

@test "delimiter: environment -> BATS_MATRIX_DELIMITER sets the default" {
    BATS_MATRIX_DELIMITER=';' run_matrix brackets <<'EOM'
        a;0;[a]
EOM
}

@test "delimiter: precedence -> the argument wins over the environment" {
    BATS_MATRIX_DELIMITER=';' run_matrix brackets ':' <<'EOM'
        a;b:0:[a;b]
EOM
}

@test "delimiter: colon -> works with a colon" {
    run_matrix brackets ':' <<'EOM'
        a : 0 : [a]
EOM
}

@test "delimiter: comma -> works with a comma" {
    run_matrix brackets ',' <<'EOM'
        a , b , 0 , [a][b]
EOM
}

@test "delimiter: custom -> lets the pipe appear in arguments and expectations" {
    run_matrix brackets ';' <<'EOM'
        a|b ; 0 ; [a|b]
EOM
}

@test "delimiter: custom -> lets a regex use alternation" {
    run_matrix brackets ';' <<'EOM'
        foo ; 0 ; ~ ^\[(foo|bar)\]$
        bar ; 0 ; ~ ^\[(foo|bar)\]$
EOM
}

@test "delimiter: custom -> the pipe is then an ordinary character in output" {
    run_matrix piped ';' <<'EOM'
        0 ; a|b
EOM
}

@test "delimiter: multiple characters -> rejected before running the command" {
    run run_matrix record '||' <<'EOM'
        unexpected | 0 | EMPTY
EOM
    [ "$status" -eq 1 ]
    [[ "$output" == *"delimiter must be one non-whitespace character"* ]]
    [ ! -f "${BATS_TEST_TMPDIR}/calls" ]
}

@test "delimiter: whitespace -> spaces, tabs and newlines are rejected" {
    local delimiter
    for delimiter in ' ' $'\t' $'\n'; do
        run run_matrix record "$delimiter" <<'EOM'
            unexpected | 0 | EMPTY
EOM
        [ "$status" -eq 1 ]
        [[ "$output" == *"delimiter must be one non-whitespace character"* ]]
        [ ! -f "${BATS_TEST_TMPDIR}/calls" ]
    done
}

# ==============================================================================
# GROUP 05: OUTPUT ASSERTIONS - SUBSTRING
# ==============================================================================

@test "substring: exact -> full output matches" {
    run_matrix brackets <<'EOM'
        a | 0 | [a]
EOM
}

@test "substring: partial -> a substring of the output matches" {
    run_matrix brackets <<'EOM'
        abcdef | 0 | cde
EOM
}

@test "substring: leading equals -> remains literal substring text" {
    run_matrix brackets <<'EOM'
        =value | 0 | =value
EOM
}

@test "substring: multi-line output -> a single line matches" {
    run_matrix two_lines <<'EOM'
        0 | line two
EOM
}

@test "substring: newlines -> documents that they are removed, so text may span lines" {
    run_matrix two_lines <<'EOM'
        0 | oneline two
EOM
}

@test "substring: carriage returns -> removed before matching" {
    run_matrix crlf_lines <<'EOM'
        0 | alphabeta
EOM
}

@test "substring: brackets and stars -> literal, not glob" {
    run_matrix brackets <<'EOM'
        * | 0 | [*]
EOM
    run run_matrix brackets <<'EOM'
        ab | 0 | [xa]
EOM
    [ "$status" -eq 1 ]
    [[ "$output" == *"Output Mismatch"* ]]
}

@test "substring: case -> matching is case sensitive" {
    run run_matrix brackets <<'EOM'
        Hello | 0 | [hello]
EOM
    [ "$status" -eq 1 ]
}

@test "substring: mismatch -> fails as Output Mismatch and shows the expectation" {
    run run_matrix brackets <<'EOM'
        hello | 0 | goodbye
EOM
    [ "$status" -eq 1 ]
    [[ "$output" == *"MATRIX TEST FAILED: Output Mismatch"* ]]
    [[ "$output" == *"Expected    : Output to contain 'goodbye'"* ]]
    [[ "$output" == *"Actual      : [hello]"* ]]
}

# ==============================================================================
# GROUP 06: OUTPUT ASSERTIONS - EMPTY
# ==============================================================================

@test "empty: keyword -> EMPTY passes when there is no output" {
    run_matrix true <<'EOM'
        0 | EMPTY
EOM
}

@test "empty: keyword -> EMPTY fails on any output" {
    run run_matrix brackets <<'EOM'
        x | 0 | EMPTY
EOM
    [ "$status" -eq 1 ]
    [[ "$output" == *"MATRIX TEST FAILED: Unexpected Output"* ]]
    [[ "$output" == *"Expected    : Empty Output"* ]]
    [[ "$output" == *"Actual      : [x]"* ]]
}

@test "empty: blank column -> behaves like EMPTY" {
    run run_matrix brackets <<'EOM'
        x | 0 |
EOM
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unexpected Output"* ]]
}

@test "empty: newline only -> output of a lone newline counts as empty" {
    run_matrix echo <<'EOM'
        0 | EMPTY
EOM
}

@test "empty: keyword -> documents that the literal text EMPTY cannot be asserted" {
    run run_matrix echo <<'EOM'
        EMPTY | 0 | EMPTY
EOM
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unexpected Output"* ]]
}

# ==============================================================================
# GROUP 07: OUTPUT ASSERTIONS - REGEX
# ==============================================================================

@test "regex: basic -> ~ prefix matches an extended regex" {
    run_matrix brackets <<'EOM'
        abc123 | 0 | ~ ^\[abc[0-9]+\]$
EOM
}

@test "regex: spacing -> whitespace after the tilde is optional" {
    run_matrix brackets <<'EOM'
        abc | 0 | ~^\[abc\]$
        abc | 0 | ~    ^\[abc\]$
EOM
}

@test "regex: trailing whitespace -> trimmed from the output before anchoring" {
    run_matrix padded <<'EOM'
        0 | ~ ^value$
EOM
}

@test "regex: multi-line output -> anchors apply to the whole output, not per line" {
    run_matrix two_lines <<'EOM'
        0 | ~ ^line one
        0 | ~ line two$
EOM
    run run_matrix two_lines <<'EOM'
        0 | ~ ^line one$
EOM
    [ "$status" -eq 1 ]
    [[ "$output" == *"Regex Mismatch"* ]]
}

@test "regex: classes -> character classes and quantifiers work" {
    run_matrix brackets <<'EOM'
        2026-01-08 | 0 | ~ [0-9]{4}-[0-9]{2}-[0-9]{2}
EOM
}

@test "regex: mismatch -> fails as Regex Mismatch and shows the regex" {
    run run_matrix brackets <<'EOM'
        abc | 0 | ~ ^[0-9]+$
EOM
    [ "$status" -eq 1 ]
    [[ "$output" == *"MATRIX TEST FAILED: Regex Mismatch"* ]]
    [[ "$output" == *"Expected    : Output to match regex '^[0-9]+$'"* ]]
    [[ "$output" == *"Actual      : [abc]"* ]]
}

@test "regex: literal tilde -> a tilde inside the expectation is not a regex marker" {
    run_matrix brackets <<'EOM'
        a~b | 0 | [a~b]
EOM
}

@test "regex: invalid syntax -> a malformed expression fails with a diagnostic" {
    run run_matrix brackets <<'EOM'
        abc | 0 | ~ [
EOM
    [ "$status" -eq 1 ]
    [[ "$output" == *"MATRIX TEST FAILED"* ]]
    [[ "$output" == *"Regex"* ]]
    [[ "$output" == *"["* ]]
}

# ==============================================================================
# GROUP 08: OUTPUT ASSERTIONS - MULTILINE
# ==============================================================================

@test "multiline: basic -> a literal \\n in the expectation matches a line break" {
    run_matrix two_lines <<'EOM'
        0 | line one\nline two
EOM
}

@test "multiline: partial -> the block may be a subset of the lines" {
    run_matrix two_lines <<'EOM'
        0 | one\nline
EOM
}

@test "multiline: order -> lines must appear in the given order" {
    run run_matrix two_lines <<'EOM'
        0 | line two\nline one
EOM
    [ "$status" -eq 1 ]
    [[ "$output" == *"MATRIX TEST FAILED: Multiline Mismatch"* ]]
}

@test "multiline: mismatch -> report shows the missing block" {
    run run_matrix two_lines <<'EOM'
        0 | line one\nline three
EOM
    [ "$status" -eq 1 ]
    [[ "$output" == *"Expected    : Strict Multiline Match"* ]]
    [[ "$output" == *"Missing Block:line one"* ]]
    [[ "$output" == *"line three"* ]]
}

@test "multiline: escapes -> \\t expands as well once \\n triggers multiline mode" {
    run_matrix tabbed <<'EOM'
        0 | a\tb\nc
EOM
}

@test "multiline: escapes -> documents that \\t alone stays literal (substring mode)" {
    run run_matrix tabbed <<'EOM'
        0 | a\tb
EOM
    [ "$status" -eq 1 ]
    [[ "$output" == *"Output Mismatch"* ]]
}

# ==============================================================================
# GROUP 09: STATUS ASSERTIONS
# ==============================================================================

@test "status: zero -> a successful command matches 0" {
    run_matrix exit_with <<'EOM'
        0 | 0 | EMPTY
EOM
}

@test "status: non-zero -> expected failures match their code" {
    run_matrix exit_with <<'EOM'
        1   | 1   | EMPTY
        2   | 2   | EMPTY
        42  | 42  | EMPTY
        255 | 255 | EMPTY
EOM
}

@test "status: mismatch -> fails as Status Mismatch with both codes" {
    run run_matrix exit_with <<'EOM'
        2 | 0 | EMPTY
EOM
    [ "$status" -eq 1 ]
    [[ "$output" == *"MATRIX TEST FAILED: Status Mismatch"* ]]
    [[ "$output" == *"Expected    : Exit Code '0'"* ]]
    [[ "$output" == *"Actual      : Exit Code '2'"* ]]
}

@test "status: precedence -> status is checked before output" {
    run run_matrix noisy_fail <<'EOM'
        0 | boom happened
EOM
    [ "$status" -eq 1 ]
    [[ "$output" == *"Status Mismatch"* ]]
    [[ "$output" != *"Output Mismatch"* ]]
}

@test "status: padding -> the status column is trimmed" {
    run_matrix exit_with <<'EOM'
        3 |   3   | EMPTY
EOM
}

@test "status: leading zeros -> expected codes are compared as decimal values" {
    run_matrix exit_with <<'EOM'
        0   | 000   | EMPTY
        8   | 08    | EMPTY
        9   | 09    | EMPTY
        10  | 010   | EMPTY
        127 | 00127 | EMPTY
        255 | 00255 | EMPTY
EOM
    [ "$status" -eq 255 ]
    [ "$output" = "" ]
}

@test "status: leading zeros -> 08 against zero reports a status mismatch" {
    run run_matrix exit_with <<'EOM'
        0 | 08 | EMPTY
EOM
    [ "$status" -eq 1 ]
    [[ "$output" == *"Status Mismatch"* ]]
    [[ "$output" == *"Expected    : Exit Code '8'"* ]]
    [[ "$output" == *"Actual      : Exit Code '0'"* ]]
    [[ "$output" != *"value too great for base"* ]]
}

@test "status: leading zeros -> 010 does not match exit code 8" {
    run run_matrix exit_with <<'EOM'
        8 | 010 | EMPTY
EOM
    [ "$status" -eq 1 ]
    [[ "$output" == *"Status Mismatch"* ]]
    [[ "$output" == *"Expected    : Exit Code '10'"* ]]
    [[ "$output" == *"Actual      : Exit Code '8'"* ]]
}

@test "status: boundaries -> every exit code from 0 through 255 matches" {
    run_matrix exit_with < <(
        for ((code=0; code<=255; code++)); do
            printf '%d | %03d | EMPTY\n' "$code" "$code"
        done
    )
    [ "$status" -eq 255 ]
    [ "$output" = "" ]
}

# ==============================================================================
# GROUP 10: FAILURE REPORTING & FEEDBACK
# ==============================================================================

@test "report: banner -> failure output carries the MATRIX TEST FAILED banner" {
    run run_matrix brackets <<'EOM'
        a | 0 | [b]
EOM
    [ "$status" -eq 1 ]
    [[ "$output" == *"================================================================================"* ]]
    [[ "$output" == *"✖ MATRIX TEST FAILED"* ]]
    [[ "$output" == *"Context:"* ]]
    [[ "$output" == *"Assertion:"* ]]
}

@test "report: command -> shows the command with each argument quoted" {
    run run_matrix brackets <<'EOM'
        hello | big world | 0 | nope
EOM
    [ "$status" -eq 1 ]
    [[ "$output" == *"Command     : brackets 'hello' 'big world'"* ]]
}

@test "report: input row -> shows the argument columns of the failing row" {
    run run_matrix brackets <<'EOM'
        a | 0 | [a]
        hello | world | 0 | nope
EOM
    [ "$status" -eq 1 ]
    [[ "$output" == *"Input Row   : hello | world"* ]]
    [[ "$output" != *"Input Row   : a"* ]]
}

@test "report: input row -> uses the delimiter in use" {
    run run_matrix brackets ';' <<'EOM'
        hello ; world ; 0 ; nope
EOM
    [ "$status" -eq 1 ]
    [[ "$output" == *"Input Row   : hello ; world"* ]]
}

@test "report: output log -> a status mismatch includes what the command printed" {
    run run_matrix noisy_fail <<'EOM'
        0 | EMPTY
EOM
    [ "$status" -eq 1 ]
    [[ "$output" == *"Output Log  :"* ]]
    [[ "$output" == *"    boom happened"* ]]
}

@test "report: multi-line actual -> indented under the Actual label" {
    run run_matrix two_lines <<'EOM'
        0 | nothing like this
EOM
    [ "$status" -eq 1 ]
    [[ "$output" == *"Actual      : "$'\n'"                  line one"$'\n'"                  line two"* ]]
}

@test "report: first failure only -> one report per matrix" {
    run run_matrix brackets <<'EOM'
        a | 0 | [x]
        b | 0 | [y]
EOM
    [ "$status" -eq 1 ]
    local count
    count=$(grep -c "MATRIX TEST FAILED" <<< "$output")
    [ "$count" -eq 1 ]
}

# ==============================================================================
# GROUP 11: STRICT MODE & COMPLIANCE
# ==============================================================================

@test "compliance: strict mode -> the suite runs with errexit, nounset, errtrace and pipefail" {
    [[ "$-" == *e* ]]
    [[ "$-" == *u* ]]
    [[ "$-" == *E* ]]
    shopt -qo pipefail
}

@test "compliance: errexit -> a failing row fails the calling test and prints the report" {
    # A consumer's test body, loaded through load.bash, in a bats process of its own:
    # bats sets errexit there, so the failing row must end the test before the echo.
    # The file is assembled with printf because bats' preprocessor would otherwise
    # read a @test line inside a heredoc as a test of this file.
    printf '%s\n' \
        "load '${BATS_TEST_DIRNAME}/../load'" \
        'brackets() { printf "[%s]" "$@"; }' \
        '@test "consumer" {' \
        '    run_matrix brackets <<< "a | 1 | [a]"' \
        '    echo "reached after failure"' \
        '}' \
        > "${BATS_TEST_TMPDIR}/consumer.bats"
    # env -i: the inner bats must not inherit the outer run's BATS_* variables.
    run -1 env -i HOME="$HOME" PATH="$PATH" "${BATS_ROOT:+${BATS_ROOT}/bin/}bats" "${BATS_TEST_TMPDIR}/consumer.bats"
    [[ "$output" == *"not ok 1 consumer"* ]]
    [[ "$output" == *"Status Mismatch"* ]]
    [[ "$output" != *"reached after failure"* ]]
}

@test "compliance: errexit -> a failing unterminated row fails the calling test" {
    # shellcheck disable=SC2016  # the generated test expands its own library path
    printf '%s\n' \
        'load "$MATRIX_LIBRARY"' \
        '@test "consumer" {' \
        '    set -Euoe pipefail' \
        '    run_matrix true < <(printf "0 | EMPTY\n1 | EMPTY")' \
        '    echo "reached after failure"' \
        '}' \
        > "${BATS_TEST_TMPDIR}/consumer.bats"
    run -1 env -i HOME="$HOME" PATH="$PATH" MATRIX_LIBRARY="$BATS_TEST_DIRNAME/../load.bash" \
        "${BATS_ROOT:+${BATS_ROOT}/bin/}bats" "${BATS_TEST_TMPDIR}/consumer.bats"
    [[ "$output" == *"not ok 1 consumer"* ]]
    [[ "$output" == *"Status Mismatch"* ]]
    [[ "$output" != *"reached after failure"* ]]
}

@test "compliance: errexit -> an 08 status mismatch fails the calling test" {
    # shellcheck disable=SC2016  # the generated test expands its own library path
    printf '%s\n' \
        'load "$MATRIX_LIBRARY"' \
        '@test "consumer" {' \
        '    set -Euoe pipefail' \
        '    run_matrix true <<< "08 | EMPTY"' \
        '    echo "reached after failure"' \
        '}' \
        > "${BATS_TEST_TMPDIR}/consumer.bats"
    run -1 env -i HOME="$HOME" PATH="$PATH" MATRIX_LIBRARY="$BATS_TEST_DIRNAME/../load.bash" \
        "${BATS_ROOT:+${BATS_ROOT}/bin/}bats" "${BATS_TEST_TMPDIR}/consumer.bats"
    [[ "$output" == *"not ok 1 consumer"* ]]
    [[ "$output" == *"Status Mismatch"* ]]
    [[ "$output" != *"value too great for base"* ]]
    [[ "$output" != *"reached after failure"* ]]
}

@test "compliance: errexit -> an overflowing status fails the calling test" {
    # shellcheck disable=SC2016  # the generated test expands its own library path
    printf '%s\n' \
        'load "$MATRIX_LIBRARY"' \
        '@test "consumer" {' \
        '    set -Euoe pipefail' \
        '    run_matrix true <<< "18446744073709551616 | EMPTY"' \
        '    echo "reached after failure"' \
        '}' \
        > "${BATS_TEST_TMPDIR}/consumer.bats"
    run -1 env -i HOME="$HOME" PATH="$PATH" MATRIX_LIBRARY="$BATS_TEST_DIRNAME/../load.bash" \
        "${BATS_ROOT:+${BATS_ROOT}/bin/}bats" "${BATS_TEST_TMPDIR}/consumer.bats"
    [[ "$output" == *"not ok 1 consumer"* ]]
    [[ "$output" == *"Matrix column 'status'"* ]]
    [[ "$output" != *"reached after failure"* ]]
}

@test "compliance: nounset -> unset MATRIX_DEBUG and BATS_MATRIX_DELIMITER do not trip set -u" {
    set -u
    unset MATRIX_DEBUG BATS_MATRIX_DELIMITER
    run_matrix brackets <<'EOM'
        a | 0 | [a]
EOM
}

@test "compliance: IFS -> the delimiter is not leaked to the command" {
    run_matrix join_ifs <<'EOM'
        0 | 1 2 3
EOM
    run_matrix join_ifs ';' <<'EOM'
        0 ; 1 2 3
EOM
}

@test "compliance: IFS -> restored for the caller after the matrix" {
    local before="$IFS"
    run_matrix brackets ';' <<'EOM'
        a;0;[a]
EOM
    [ "$IFS" = "$before" ]
}

@test "compliance: locale -> LC_ALL is left alone for the caller and the command" {
    local before="${LC_ALL-unset}"
    run_matrix brackets <<'EOM'
        café | 0 | ~ ^\[[[:alpha:]]{4}\]$
EOM
    [ "${LC_ALL-unset}" = "$before" ]
}

@test "compliance: globals -> status and output hold the last row after the matrix" {
    run_matrix brackets <<'EOM'
        a | 0 | [a]
        b | 0 | [b]
EOM
    [ "$status" -eq 0 ]
    [ "$output" = "[b]" ]
    run_matrix exit_with <<'EOM'
        2 | 2 | EMPTY
EOM
    [ "$status" -eq 2 ]
}

@test "compliance: return value -> 0 on success, 1 on any failure" {
    local rc=0
    run_matrix brackets <<'EOM' || rc=$?
        a | 0 | [a]
EOM
    [ "$rc" -eq 0 ]
    run_matrix brackets <<'EOM' || rc=$?
        a | 0 | [b]
EOM
    [ "$rc" -eq 1 ]
}

# ==============================================================================
# GROUP 12: INTERACTIONS
# ==============================================================================

@test "interaction: function -> a shell function is a valid target" {
    run_matrix brackets <<'EOM'
        a | 0 | [a]
EOM
}

@test "interaction: binary -> an external command is a valid target" {
    run_matrix basename <<'EOM'
        /usr/local/bin | 0 | bin
EOM
}

@test "interaction: builtin -> a shell builtin is a valid target" {
    run_matrix echo <<'EOM'
        hello | 0 | hello
EOM
}

@test "interaction: stdin -> the command reads /dev/null, not the remaining rows" {
    run_matrix cat <<'EOM'
        0 | EMPTY
        0 | EMPTY
EOM
}

@test "interaction: nested run -> a target that calls run does not confuse the matrix" {
    run_matrix uses_run <<'EOM'
        0 | inner status 1
EOM
}

# ==============================================================================
# GROUP 13: CONFIGURATION & DEBUGGING
# ==============================================================================

@test "debug: off -> no DEBUG lines by default" {
    run run_matrix brackets <<'EOM'
        a | 0 | [a]
EOM
    [ "$status" -eq 0 ]
    [[ "$output" != *"DEBUG"* ]]
}

@test "debug: on -> MATRIX_DEBUG prints every row before it runs" {
    MATRIX_DEBUG=1 run run_matrix brackets <<'EOM'
        a | 0 | [a]
        b | c | 0 | [b][c]
EOM
    [ "$status" -eq 0 ]
    [[ "$output" == *"DEBUG: run_matrix -> args:[a] status:[0] expect:[[a]]"* ]]
    [[ "$output" == *"DEBUG: run_matrix -> args:[b c] status:[0] expect:[[b][c]]"* ]]
}

@test "debug: stderr -> debug lines go to stderr, not into the asserted output" {
    MATRIX_DEBUG=1 run_matrix brackets 2>/dev/null <<'EOM'
        a | 0 | [a]
EOM
    [ "$output" = "[a]" ]
}

# ==============================================================================
# GROUP 14: SECURITY & SAFETY
# ==============================================================================

@test "security: arguments -> command substitution in a row is not evaluated" {
    local exploit_file="${BATS_TEST_TMPDIR}/pwned"
    run_matrix brackets <<EOM
        \$(touch $exploit_file) | 0 | [\$(touch $exploit_file)]
EOM
    [ ! -f "$exploit_file" ]
}

@test "security: arguments -> backticks in a row are not evaluated" {
    local exploit_file="${BATS_TEST_TMPDIR}/pwned"
    run_matrix brackets <<EOM
        \`touch $exploit_file\` | 0 | [\`touch $exploit_file\`]
EOM
    [ ! -f "$exploit_file" ]
}

@test "security: arguments -> shell operators in a row are literal" {
    run_matrix brackets <<'EOM'
        a; b && c | 0 | [a; b && c]
        a > /dev/null | 0 | [a > /dev/null]
EOM
}

@test "security: expectation -> command substitution in the expectation is not evaluated" {
    local exploit_file="${BATS_TEST_TMPDIR}/pwned"
    run run_matrix brackets <<EOM
        a | 0 | \$(touch $exploit_file)
EOM
    [ "$status" -eq 1 ]
    [ ! -f "$exploit_file" ]
}

@test "security: command name -> is one word, never parsed as shell code" {
    local exploit_file="${BATS_TEST_TMPDIR}/pwned"
    run_matrix "true; touch $exploit_file" <<'EOM'
        127 | pwned
EOM
    [ ! -f "$exploit_file" ]
}

# ==============================================================================
# GROUP 15: ERROR HANDLING
# ==============================================================================

@test "error: status column -> non-integer is rejected before running anything" {
    run run_matrix record <<'EOM'
        a | ok | [a]
EOM
    [ "$status" -eq 1 ]
    [[ "$output" == *"Matrix column 'status' must be a decimal integer from 0 to 255. Got: 'ok'"* ]]
    [ ! -f "${BATS_TEST_TMPDIR}/calls" ]
}

@test "error: status column -> negative numbers are rejected" {
    run run_matrix brackets <<'EOM'
        a | -1 | [a]
EOM
    [ "$status" -eq 1 ]
    [[ "$output" == *"must be a decimal integer from 0 to 255"* ]]
}

@test "error: status column -> empty status is rejected" {
    run run_matrix brackets <<'EOM'
        a |  | [a]
EOM
    [ "$status" -eq 1 ]
    [[ "$output" == *"must be a decimal integer from 0 to 255"* ]]
}

@test "error: status column -> 256 is rejected before executing the command" {
    run run_matrix record <<'EOM'
        unexpected | 256 | EMPTY
EOM
    [ "$status" -eq 1 ]
    [[ "$output" == *"decimal integer from 0 to 255"* ]]
    [[ "$output" == *"Got: '256'"* ]]
    [ ! -f "${BATS_TEST_TMPDIR}/calls" ]
}

@test "error: status column -> overflowing values cannot wrap around to zero" {
    run run_matrix record <<'EOM'
        unexpected | 18446744073709551616 | EMPTY
EOM
    [ "$status" -eq 1 ]
    [[ "$output" == *"decimal integer from 0 to 255"* ]]
    [[ "$output" == *"Got: '18446744073709551616'"* ]]
    [ ! -f "${BATS_TEST_TMPDIR}/calls" ]
}

@test "error: status column -> arithmetic expressions are rejected as text" {
    run run_matrix record <<'EOM'
        unexpected | 1+1 | EMPTY
EOM
    [ "$status" -eq 1 ]
    [[ "$output" == *"Got: '1+1'"* ]]
    [ ! -f "${BATS_TEST_TMPDIR}/calls" ]
}

@test "error: status column -> hexadecimal notation is rejected" {
    run run_matrix record <<'EOM'
        unexpected | 0x10 | EMPTY
EOM
    [ "$status" -eq 1 ]
    [[ "$output" == *"Got: '0x10'"* ]]
    [ ! -f "${BATS_TEST_TMPDIR}/calls" ]
}

@test "error: later invalid row -> earlier rows run, invalid and later rows do not" {
    run run_matrix record <<'EOM'
        first   | 0   | EMPTY
        invalid | 256 | EMPTY
        last    | 0   | EMPTY
EOM
    [ "$status" -eq 1 ]
    [[ "$output" == *"Got: '256'"* ]]
    run cat "${BATS_TEST_TMPDIR}/calls"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
    [ "${lines[0]}" = "called first" ]
}

@test "error: columns -> a row with a single column is rejected" {
    run run_matrix brackets <<'EOM'
        only-one-column
EOM
    [ "$status" -eq 1 ]
    [[ "$output" == *"Malformed matrix row"* ]]
    [[ "$output" == *"only-one-column"* ]]
}

@test "error: input -> a heredoc with only comments is an error" {
    run run_matrix brackets <<'EOM'
        # nothing but a comment
EOM
    [ "$status" -eq 1 ]
    [[ "$output" == *"no valid input lines"* ]]
}

@test "error: input -> no stdin at all is an error" {
    run run_matrix brackets < /dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"no valid input lines"* ]]
}

@test "error: input -> an unterminated comment alone is an error" {
    run run_matrix record < <(printf '%s' '# no rows')
    [ "$status" -eq 1 ]
    [[ "$output" == *"no valid input lines"* ]]
    [ ! -f "${BATS_TEST_TMPDIR}/calls" ]
}

@test "error: command -> a missing command name is an error" {
    run run_matrix <<'EOM'
        0 | EMPTY
EOM
    [ "$status" -eq 1 ]
    [[ "$output" == *"requires a function name"* ]]
}

@test "error: arguments -> extra runner arguments are rejected before execution" {
    run run_matrix record '|' unexpected <<'EOM'
        unexpected | 0 | EMPTY
EOM
    [ "$status" -eq 1 ]
    [[ "$output" == *"usage: run_matrix COMMAND [DELIMITER]"* ]]
    [ ! -f "${BATS_TEST_TMPDIR}/calls" ]
}

@test "error: command -> an unknown command is a normal 127 row, without bats warning BW01" {
    run_matrix no_such_command_here <<'EOM'
        127 | ~ command not found
EOM
}

@test "error: command -> a row that expects 127 still reports a mismatch on another code" {
    run run_matrix exit_with <<'EOM'
        3 | 127 | EMPTY
EOM
    [ "$status" -eq 1 ]
    [[ "$output" == *"Expected    : Exit Code '127'"* ]]
    [[ "$output" == *"Actual      : Exit Code '3'"* ]]
}

# ==============================================================================
# GROUP 16: ENVIRONMENT GUARDS
# ==============================================================================

@test "guard: bash version -> refuses Bash older than 4" {
    run matrix::internal::require_bash4 3
    [ "$status" -eq 1 ]
    [[ "$output" == *"requires Bash 4.0+"* ]]
}

@test "guard: bash version -> accepts Bash 4, newer, and the running shell" {
    matrix::internal::require_bash4 4
    matrix::internal::require_bash4 5
    matrix::internal::require_bash4
}

@test "guard: dependencies -> refuses to run without bats-core's run" {
    run without_run
    [ "$status" -eq 1 ]
    [[ "$output" == *"requires 'run' (bats-core)"* ]]
}

@test "guard: run failure -> stale results cannot turn a broken run into a pass" {
    # shellcheck disable=SC2016  # the replacement run exists only in the child bash
    run bash -euo pipefail -c '
        source "$1"
        run() { return 2; }
        status=0
        output=stale
        run_matrix true <<< "0 | stale" || exit $?
    ' _ "$BATS_TEST_DIRNAME/../src/matrix.bash"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MATRIX TEST FAILED: Runner Failure"* ]]
    [[ "$output" == *"run returned 2"* ]]
    [[ "$output" != *"Output Log"* ]]
}

@test "guard: run failure -> expecting 127 does not hide an infrastructure error" {
    # shellcheck disable=SC2016  # the replacement run exists only in the child bash
    run bash -euo pipefail -c '
        source "$1"
        run() { return 2; }
        run_matrix true <<< "127 | EMPTY"
    ' _ "$BATS_TEST_DIRNAME/../src/matrix.bash"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MATRIX TEST FAILED: Runner Failure"* ]]
    [[ "$output" == *"run returned 2"* ]]
}

@test "guard: fail polyfill -> fail exists, prints to stderr and returns 1" {
    declare -F fail > /dev/null
    run --separate-stderr fail "polyfilled failure"
    [ "$status" -eq 1 ]
    [ "$output" = "" ]
    [ "$stderr" = "polyfilled failure" ]
}

@test "guard: fail polyfill -> leading flags and backslashes are printed literally" {
    run --separate-stderr fail '-n' '\t'
    [ "$status" -eq 1 ]
    [ "$output" = "" ]
    [ "$stderr" = '-n \t' ]
}

@test "guard: load -> loading the file twice is harmless" {
    load "$BATS_TEST_DIRNAME/../src/matrix.bash"
    run_matrix brackets <<'EOM'
        a | 0 | [a]
EOM
}

@test "guard: load -> sourcing the library twice is silent under strict mode" {
    # shellcheck disable=SC2016  # the source path is passed to the child bash
    run --separate-stderr bash -euo pipefail -c 'source "$1"; source "$1"' \
        _ "$BATS_TEST_DIRNAME/../src/matrix.bash"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    [ "$stderr" = "" ]
}

@test "guard: load -> the public loader is silent on repeated loads" {
    # shellcheck disable=SC2016  # the source path is passed to the child bash
    run --separate-stderr bash -euo pipefail -c 'source "$1"; source "$1"' \
        _ "$BATS_TEST_DIRNAME/../load.bash"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    [ "$stderr" = "" ]
}

@test "guard: fail polyfill -> an existing fail helper is preserved without output" {
    # shellcheck disable=SC2016  # the function and its arguments belong to the child bash
    run --separate-stderr bash -euo pipefail -c \
        'fail() { printf "existing:%s\n" "$*" >&2; return 1; }; source "$1"; fail message' \
        _ "$BATS_TEST_DIRNAME/../load.bash"
    [ "$status" -eq 1 ]
    [ "$output" = "" ]
    [ "$stderr" = "existing:message" ]
}

# ==============================================================================
# GROUP 17: INTERNAL API (WHITEBOX)
# ==============================================================================

@test "whitebox: assert::status -> returns 0 on match, 1 on mismatch" {
    matrix::assert::status 0 0 "cmd" "'a'" "a" ""
    run matrix::assert::status 0 1 "cmd" "'a'" "a" "some output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Status Mismatch"* ]]
    [[ "$output" == *"some output"* ]]
}

@test "whitebox: assert::status -> a missing actual status cannot equal zero" {
    run matrix::assert::status 0 "" "cmd" "" "row" ""
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid Status"* ]]
}

@test "whitebox: assert::status -> overflowing expected and actual values are rejected" {
    run matrix::assert::status 18446744073709551616 0 "cmd" "" "row" ""
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid Status"* ]]
    run matrix::assert::status 0 18446744073709551616 "cmd" "" "row" ""
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid Status"* ]]
}

@test "whitebox: assert::output -> dispatches EMPTY, regex, multiline and substring" {
    matrix::assert::output "EMPTY" "" "cmd" "" "row"
    matrix::assert::output "" "" "cmd" "" "row"
    matrix::assert::output "~ ^ab" "abc" "cmd" "" "row"
    matrix::assert::output 'a\nb' $'a\nb' "cmd" "" "row"
    matrix::assert::output "b" "abc" "cmd" "" "row"
}

@test "whitebox: assert::output -> an invalid regex is rejected with context" {
    run matrix::assert::output '~ [' 'abc' 'cmd' "'arg'" 'input row'
    [ "$status" -eq 1 ]
    [[ "$output" == *"MATRIX TEST FAILED: Invalid Regex"* ]]
    [[ "$output" == *"Input Row   : input row"* ]]
    [[ "$output" == *"Command     : cmd 'arg'"* ]]
    [[ "$output" == *"Actual      : ["* ]]
}

@test "whitebox: assert::output -> each mode reports its own failure type" {
    run matrix::assert::output "EMPTY" "x" "cmd" "" "row"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unexpected Output"* ]]
    run matrix::assert::output "~ ^z" "abc" "cmd" "" "row"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Regex Mismatch"* ]]
    run matrix::assert::output 'a\nz' $'a\nb' "cmd" "" "row"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Multiline Mismatch"* ]]
    run matrix::assert::output "z" "abc" "cmd" "" "row"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Output Mismatch"* ]]
}

@test "whitebox: assert::multiline -> expands escapes and requires the exact block" {
    matrix::assert::multiline 'one\ntwo' $'zero\none\ntwo\nthree' "cmd" "" "row"
    run matrix::assert::multiline 'two\none' $'one\ntwo' "cmd" "" "row"
    [ "$status" -eq 1 ]
}

@test "whitebox: internal::fail -> formats context, assertion and an optional log block" {
    run matrix::internal::fail "Custom Type" "cmd" "'a' 'b'" "a | b" "the expectation" "the actual" "log line"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MATRIX TEST FAILED: Custom Type"* ]]
    [[ "$output" == *"Input Row   : a | b"* ]]
    [[ "$output" == *"Command     : cmd 'a' 'b'"* ]]
    [[ "$output" == *"Expected    : the expectation"* ]]
    [[ "$output" == *"Actual      : the actual"* ]]
    [[ "$output" == *"Output Log  :"* ]]
    [[ "$output" == *"    log line"* ]]
}

@test "whitebox: internal::fail -> omits the log block when there is no log" {
    run matrix::internal::fail "Custom Type" "cmd" "" "" "e" "a"
    [ "$status" -eq 1 ]
    [[ "$output" != *"Output Log"* ]]
}

@test "whitebox: internal::fail -> indents a multi-line actual value" {
    run matrix::internal::fail "Custom Type" "cmd" "" "" "e" $'first\nsecond'
    [ "$status" -eq 1 ]
    [[ "$output" == *"                  first"$'\n'"                  second"* ]]
}

# ==============================================================================
# GROUP 18: SCALE
# ==============================================================================

@test "scale: rows -> 200 rows run in order" {
    run_matrix record < <(for i in $(seq 1 200); do echo "$i | 0 | EMPTY"; done)
    run cat "${BATS_TEST_TMPDIR}/calls"
    [ "${#lines[@]}" -eq 200 ]
    [ "${lines[0]}" = "called 1" ]
    [ "${lines[199]}" = "called 200" ]
}

@test "scale: wide rows -> 12 arguments in one row" {
    run_matrix brackets <<'EOM'
        1|2|3|4|5|6|7|8|9|10|11|12| 0 |[1][2][3][4][5][6][7][8][9][10][11][12]
EOM
}

@test "scale: huge argument -> a 10k character argument round-trips" {
    local huge
    huge=$(printf 'a%.0s' {1..10000})
    run_matrix brackets <<EOM
        $huge | 0 | [$huge]
EOM
}

@test "scale: huge output -> a 10k character output is matched by an anchored regex" {
    local huge
    huge=$(printf 'b%.0s' {1..10000})
    run_matrix brackets <<EOM
        $huge | 0 | ~ ^\[b+\]$
EOM
}
