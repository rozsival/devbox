log_info() { echo -e "\033[0;34m[INFO]\033[0m  $*"; }
log_success() { echo -e "\033[0;32m[OK]\033[0m    $*"; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m  $*" >&2; }
log_error() {
  echo -e "\033[0;31m[ERROR]\033[0m $*" >&2
  exit 1
}

# A failed check: reported, counted, and left for finish_checks to turn into
# the exit status.
fail() {
  log_warn "$*"
  failures=$((failures + 1))
}

finish_checks() {
  echo
  ((failures == 0)) || log_error "${failures} check(s) failed."
  log_success 'All checks passed.'
}
