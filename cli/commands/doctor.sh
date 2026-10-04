side="${args[side]:-}"
if [[ -z "${side}" ]]; then
  if on_host; then
    side=host
  elif on_laptop; then
    side=laptop
  else
    log_error 'Neither the workstation nor the laptop: run doctor on one of them (the container has no docker and no keys).'
  fi
fi

case "${side}" in
host)
  [[ -z "$(filter_host)" ]] || log_error "$(filter_host)"
  doctor_host
  ;;
laptop)
  [[ -z "$(filter_laptop)" ]] || log_error "$(filter_laptop)"
  doctor_laptop
  ;;
esac
