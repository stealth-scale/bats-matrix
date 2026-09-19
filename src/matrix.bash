#
# BATS Matrix Runner
#
# A data-driven test runner for BATS that allows defining test cases in a
# clean, pipe-delimited table format.
#
# Features:
#   - Strict Mode Compliant (set -Euoe pipefail).
#   - Pure Bash parsing (no subshells in loops for performance).
#   - Robust input handling via Sentinel pattern.
#   - Strict type checking for status codes.
#   - Regex matching support via '~' prefix.
#   - Scoped IFS handling (prevents leaking delimiters to commands).
#
# Usage:
#   load "lib/matrix.bash"
#
#   # arg1 | arg2 | status | output
#   run_matrix "my_command" <<EOM
#       foo | bar | 0 | success
#   EOM

# Default delimiter. Uses := to safely set if unset/null, compliant with set -u.
: "${BATS_MATRIX_DELIMITER:=|}"

# Polyfill the fail function
if ! declare -F fail; then
    fail() {
        echo "$@" >&2
        return 1
    }
fi

#######################################
# Refuses Bash older than 4.0. The array handling below needs it, and
# macOS still ships Bash 3.2.
#
# Arguments:
#   $1 (Integer) - (Optional) Major version to check, defaults to the running shell
# Returns:
#   0 - Version is 4 or newer
#   1 - Version is older (after calling 'fail')
#######################################
matrix::internal::require_bash4() {
    local major="${1:-${BASH_VERSINFO[0]}}"
    if (( major < 4 )); then
        fail "Matrix runner requires Bash 4.0+"
        return 1
    fi
}

# Stop loading on an old shell instead of failing later inside a test.
matrix::internal::require_bash4 || return 1

# ------------------------------------------------------------------------------
# Private Helpers
# ------------------------------------------------------------------------------

#######################################
# Formats and prints a failure message using BATS 'fail'.
# Handles multiline output formatting and alignment.
#
# Globals:
#   None
# Arguments:
#   $1 (String) - Failure type description
#   $2 (String) - Name of the function tested
#   $3 (String) - Formatted arguments string
#   $4 (String) - Reconstructed input row
#   $5 (String) - Description of expected value
#   $6 (String) - Description of actual value received
#   $7 (String) - (Optional) Additional log output
# Returns:
#   None (Exits test via 'fail')
#######################################
matrix::internal::fail() {
    # strict-mode safe argument retrieval
    local failure_type="${1:-}"
    local func_name="${2:-}"
    local args_str="${3:-}"
    local raw_line="${4:-}"
    local expected_val="${5:-}"
    local actual_val="${6:-}"
    local extra_log="${7:-}"

    local label_width=12
    local val_indent="                  "
    local formatted_actual
    local block_log=""
    local line_expected
    local line_actual

    # Format multi-line actual values with indentation
    if [[ "${actual_val}" == *$'\n'* ]]; then
        # Use printf to avoid 'echo' interpreting flags like -n or -e
        formatted_actual=$'\n'"$(printf '%s' "${actual_val}" | sed "s/^/${val_indent}/")"
    else
        formatted_actual="${actual_val}"
    fi

    # formatting: 'Expected: <value>'
    printf -v line_expected "    %-${label_width}s: %s" "Expected" "${expected_val}"
    # formatting: 'Actual:   <value>'
    printf -v line_actual   "    %-${label_width}s: %s" "Actual"   "${formatted_actual}"

    # Format optional log block if provided
    if [[ -n "${extra_log}" ]]; then
        local log_indent="    "
        local indented_log
        indented_log="$(printf '%s' "${extra_log}" | sed "s/^/${log_indent}/")"

        local line_log_label
        printf -v line_log_label "    %-${label_width}s:" "Output Log"
        block_log=$'\n'"${line_log_label}"$'\n'$'\n'"${indented_log}"
    fi

    fail "
================================================================================
  ✖ MATRIX TEST FAILED: ${failure_type}
================================================================================
  Context:
    Input Row   : ${raw_line}
    Command     : ${func_name} ${args_str}

  Assertion:
${line_expected}
${line_actual}${block_log}
================================================================================"
}

#######################################
# Asserts that the command exit status matches the expectation.
# Delegates failure reporting to matrix::internal::fail.
#
# Globals:
#   None
# Arguments:
#   $1 (Integer) - Expected exit code
#   $2 (Integer) - Actual exit code
#   $3 (String)  - Name of the function tested
#   $4 (String)  - Formatted arguments string
#   $5 (String)  - Input matrix line
#   $6 (String)  - Command output (for logging context)
# Returns:
#   0 - Status matches
#   1 - Status mismatch (triggers failure)
#######################################
matrix::assert::status() {
    local expected="${1:-}"
    local actual="${2:-}"
    local func_name="${3:-}"
    local args_str="${4:-}"
    local raw_line="${5:-}"
    local output_log="${6:-}"

    if [[ "${actual}" -ne "${expected}" ]]; then
        matrix::internal::fail "Status Mismatch" "${func_name}" "${args_str}" "${raw_line}" \
            "Exit Code '${expected}'" \
            "Exit Code '${actual}'" \
            "${output_log}"
        return 1
    fi
    return 0
}

#######################################
# Asserts strict multiline matching.
# Expands literal '\n' sequences in the expectation and checks
# if the actual output contains the resulting block, preserving newlines.
#
# Globals:
#   None
# Arguments:
#   $1 (String) - Expected output string or regex (starting with ~)
#   $2 (String) - Actual output captured from command
#   $3 (String) - Name of the function tested
#   $4 (String) - Formatted arguments string
#   $5 (String) - Input matrix line
# Returns:
#   0 - Output matches
#   1 - Output mismatch (triggers failure)
#######################################
matrix::assert::multiline() {
    local expected="${1:-}"
    local actual="${2:-}"
    local func_name="${3:-}"
    local args_str="${4:-}"
    local raw_line="${5:-}"

    # 1. Expansion: Convert literal '\n' characters into real newlines.
    # We use 'printf %b' which reliably expands backslash escapes.
    local expected_expanded
    printf -v expected_expanded "%b" "${expected}"

    # 2. Strict Substring Check (No normalization of 'actual')
    # We check if the raw actual output contains the expanded block.
    if [[ "${actual}" != *"${expected_expanded}"* ]]; then

         # We pass the multiline expectation as 'extra_log' ($7)
         # so matrix::internal::fail handles the indentation correctly.
         matrix::internal::fail "Multiline Mismatch" "${func_name}" "${args_str}" "${raw_line}" \
            "Strict Multiline Match" \
            "${actual}" \
            "Missing Block:${expected_expanded}"
         return 1
    fi
    return 0
}

#######################################
# Asserts that the command output matches the expectation.
# Supports 'EMPTY', simple substrings, and Regex (via '~' prefix).
#
# Globals:
#   None
# Arguments:
#   $1 (String) - Expected output string or regex (starting with ~)
#   $2 (String) - Actual output captured from command
#   $3 (String) - Name of the function tested
#   $4 (String) - Formatted arguments string
#   $5 (String) - Input matrix line
# Returns:
#   0 - Output matches
#   1 - Output mismatch (triggers failure)
#######################################
matrix::assert::output() {
    local expected="${1:-}"
    local actual="${2:-}"
    local func_name="${3:-}"
    local args_str="${4:-}"
    local raw_line="${5:-}"

    # 1. Empty Check
    if [[ -z "${expected}" || "${expected}" == "EMPTY" ]]; then
        if [[ -n "${actual}" ]]; then
            matrix::internal::fail "Unexpected Output" "${func_name}" "${args_str}" "${raw_line}" \
                "Empty Output" \
                "${actual}"
            return 1
        fi
        return 0
    fi

    # 2. Regex Check (Prefix '~')
    # Use regex check to reliably detect literal tilde prefix without glob expansion issues
    if [[ "${expected}" =~ ^~ ]]; then
        # Use substring extraction to skip the first character (tilde) safely
        local regex="${expected:1}"

        # Trim potential leading space after the tilde
        regex="${regex#"${regex%%[![:space:]]*}"}"

        # Trim trailing whitespace from actual to ensure '$' anchors work as expected on line output
        local trimmed_actual="${actual}"
        trimmed_actual="${trimmed_actual%"${trimmed_actual##*[![:space:]]}"}"

        if [[ ! "${trimmed_actual}" =~ ${regex} ]]; then
             matrix::internal::fail "Regex Mismatch" "${func_name}" "${args_str}" "${raw_line}" \
                "Output to match regex '${regex}'" \
                "${actual}"
             return 1
        fi
        return 0
    fi

    # 3. Strict Multiline Check
    # Triggers if the expectation contains a literal backslash followed by 'n'.
    if [[ "${expected}" == *"\\n"* ]]; then
        matrix::assert::multiline "${expected}" "${actual}" "${func_name}" \
            "${args_str}" "${raw_line}"
        return $?
    fi

    # 4. Substring Check (Default)
    # Optimization: Pure bash replace to remove newlines/CRs for robust single-line matching
    local normalized_actual="${actual//$'\n'/}"
    normalized_actual="${normalized_actual//$'\r'/}"

    if [[ "${normalized_actual}" != *"${expected}"* ]]; then
         matrix::internal::fail "Output Mismatch" "${func_name}" "${args_str}" "${raw_line}" \
            "Output to contain '${expected}'" \
            "${actual}"
         return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# Public API
# ------------------------------------------------------------------------------

#######################################
# Executes a test function against a table of inputs and expectations.
# Reads a pipe-delimited table from stdin (heredoc).
#
# Globals:
#   BATS_MATRIX_DELIMITER (Read) - Default delimiter
#   MATRIX_DEBUG (Read)          - Toggles debug output
#   status (Read/Write)          - From bats-core (last run exit code)
#   output (Read/Write)          - From bats-core (last run output)
# Arguments:
#   $1 (String) - The target function/command to run
#   $2 (String) - (Optional) Custom delimiter override
# Returns:
#   0 - All rows passed
#   1 - Any row failed
# Usage:
#   matrix::runner::execute "target_command" <<EOM
#     arg1 | 0 | expected_output
#   EOM
#######################################
matrix::runner::execute() {
    local func_name="${1:-}"
    local delimiter="${2:-${BATS_MATRIX_DELIMITER:-|}}"
    local line
    local has_input=0

    # Strict mode: Validate required argument
    if [[ -z "${func_name}" ]]; then
        fail "Error: run_matrix requires a function name as the first argument."
        return 1
    fi

    # Dependency check
    if ! declare -f run >/dev/null || ! declare -f fail >/dev/null; then
        printf "Error: run_matrix requires 'run' (bats-core) and 'fail' (bats-support).\n" >&2
        return 1
    fi

    # Loop consumes stdin. 'read' will return false at EOF, handling set -e safely.
    while read -r line; do
        # Skip empty lines and comments
        [[ "${line}" =~ ^[[:space:]]*$ || "${line}" =~ ^[[:space:]]*# ]] && continue
        has_input=1

        # The Sentinel Pattern:
        # We prepend/append 'SENTINEL' to handle empty start/end fields correctly.
        # This prevents `read` from dropping empty trailing delimiters.

        local parts
        # SCOPED IFS FIX: We set IFS only for this read command.
        # This prevents IFS from leaking into the 'run' command scope later.
        IFS="${delimiter}" read -r -a parts <<< "SENTINEL${delimiter}${line}${delimiter}SENTINEL"

        local total_fields="${#parts[@]}"
        # Minimum required: Sentinel + Arg1 + Status + Output + Sentinel = 5 fields
        # (Allows 0 args: Sentinel + Status + Output + Sentinel = 4 fields)
        if (( total_fields < 4 )); then
             fail "Error: Malformed matrix row. Expected at least 'Status | Output'. Row: ${line}"
             return 1
        fi

        local idx_out=$((total_fields - 2))
        local idx_stat=$((total_fields - 3))

        local args=()
        local args_display=""
        local clean_line=""
        local raw_val
        local val
        local i

        # Parse Arguments (Columns 1 to N-2)
        # Optimization: Moved trimming logic inline to avoid subshell overhead
        # Loop indices are mathematically safe based on checks above.
        for ((i=1; i<idx_stat; i++)); do
            raw_val="${parts[$i]}"

            # Inline Trim
            val="${raw_val}"
            val="${val#"${val%%[![:space:]]*}"}"
            val="${val%"${val##*[![:space:]]}"}"

            args+=("${val}")
            args_display+="'${val}' "
            clean_line+="${val} ${delimiter} "
        done

        args_display="${args_display% }"
        clean_line="${clean_line% ${delimiter} }"

        # Parse Expectations
        local expected_output="${parts[$idx_out]}"
        expected_output="${expected_output#"${expected_output%%[![:space:]]*}"}"
        expected_output="${expected_output%"${expected_output##*[![:space:]]}"}"

        local expected_status="${parts[$idx_stat]}"
        expected_status="${expected_status#"${expected_status%%[![:space:]]*}"}"
        expected_status="${expected_status%"${expected_status##*[![:space:]]}"}"

        # Debug Mode - use :- to prevent nounset on MATRIX_DEBUG
        if [[ -n "${MATRIX_DEBUG:-}" ]]; then
            printf >&2 "DEBUG: run_matrix -> args:[%s] status:[%s] expect:[%s]\n" \
                "${args[*]}" "${expected_status}" "${expected_output}"
        fi

        # Validation: Ensure status is an integer
        if [[ ! "${expected_status}" =~ ^[0-9]+$ ]]; then
            fail "Error: Matrix column 'status' must be a positive integer. Got: '${expected_status}' in row: ${clean_line}"
            return 1
        fi

        # Execution via bats-core 'run'
        # Since IFS was not set globally in the loop, this runs with default IFS (space/tab/newline)
        # CRITICAL FIX: Redirect stdin to /dev/null to prevent the command from consuming the matrix heredoc
        # A bare 'run' that sees 127 raises bats warning BW01. When the row expects 127, state that
        # intent with 'run -127' (bats-core 1.5.0+) and leave the verdict to the assertions below.
        if [[ "${expected_status}" -eq 127 ]]; then
            run -127 "${func_name}" "${args[@]}" < /dev/null || true
        else
            run "${func_name}" "${args[@]}" < /dev/null
        fi

        # Assertions
        # Decoupled Logic: Delegate to helper functions
        # We explicitly pass globals 'status' and 'output' to helpers as arguments
        # Use ${status:-} and ${output:-} to prevent strict mode crashes if run failed catastrophically
        matrix::assert::status "${expected_status}" "${status:-}" "${func_name}" \
            "${args_display}" "${clean_line}" "${output:-}" || return 1

        matrix::assert::output "${expected_output}" "${output:-}" "${func_name}" \
            "${args_display}" "${clean_line}" || return 1

    done

    if [[ "${has_input}" -eq 0 ]]; then
        fail "Error: run_matrix called with no valid input lines."
    fi
}

#######################################
# Executes a test function against a table of inputs and expectations.
# Reads a pipe-delimited table from stdin (heredoc).
#
# Globals:
#   BATS_MATRIX_DELIMITER (Read) - Default delimiter
#   MATRIX_DEBUG (Read)          - Toggles debug output
#   status (Read/Write)          - From bats-core (last run exit code)
#   output (Read/Write)          - From bats-core (last run output)
# Arguments:
#   $1 (String) - The target function/command to run
#   $2 (String) - (Optional) Custom delimiter override
# Returns:
#   0 - All rows passed
#   1 - Any row failed
# Usage:
#   run_matrix "target_command" <<EOM
#     arg1 | 0 | expected_output
#   EOM
#######################################
run_matrix() {
    matrix::runner::execute "$@"
}

