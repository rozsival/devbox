require_env_file() {
  [[ -f "${ENV_FILE}" ]] || log_error "Missing ${ENV_FILE} - run './bin/devbox env' (template: ${ENV_EXAMPLE})."
}

# Reads a single key. Deliberately not `source`: .env holds unquoted UTF-8 values
# that compose parses fine but bash would try to execute.
env_get() {
  local key="$1" value
  value="$(grep -E "^${key}=" "${ENV_FILE}" 2>/dev/null | tail -1 || true)"
  value="${value#*=}"
  value="${value%\"}"
  value="${value#\"}"
  printf '%s' "${value}"
}

# Sets a key, keeping the file's owner and mode: `docker setup` runs as root
# and .env belongs to the deploying user. Under CHECK_ONLY a differing value is
# reported instead.
upsert_env_key() {
  local key="$1" value="$2" tmp
  [[ "$(env_get "${key}")" == "${value}" ]] && return 0
  if [[ "${CHECK_ONLY}" == 'true' ]]; then
    fail "${ENV_FILE}: ${key} is '$(env_get "${key}")', expected '${value}'"
    return 0
  fi
  tmp="$(mktemp)"
  if grep -qE "^${key}=" "${ENV_FILE}"; then
    KEY="${key}" VALUE="${value}" awk -F= '
      BEGIN { k = ENVIRON["KEY"]; v = ENVIRON["VALUE"] }
      $1 == k && !replaced { print k "=" v; replaced = 1; next }
      { print }
    ' "${ENV_FILE}" >"${tmp}"
  else
    cat "${ENV_FILE}" >"${tmp}"
    printf '%s=%s\n' "${key}" "${value}" >>"${tmp}"
  fi
  chown --reference="${ENV_FILE}" "${tmp}"
  chmod --reference="${ENV_FILE}" "${tmp}"
  mv "${tmp}" "${ENV_FILE}"
  log_success "${ENV_FILE}: ${key}=${value}"
}
