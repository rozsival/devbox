require_env_file
if [[ -n "${args[--follow]:-}" ]]; then
  compose logs -f "${SERVICE}"
else
  compose logs --tail 100 "${SERVICE}"
fi
