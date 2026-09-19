# Entry point for `load` and `bats_load_library`. Sources the library from src/.
#
#   load 'test_helper/bats-matrix/load'
#
# shellcheck source=src/matrix.bash
source "$(dirname "${BASH_SOURCE[0]}")/src/matrix.bash"
