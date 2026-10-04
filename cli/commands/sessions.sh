require_env_file
# Peer address plus the login records sshd wrote, so an unexplained disconnect
# can be traced: "Accepted publickey" without a matching close means the
# container went away under the session.
compose exec -T "${SERVICE}" \
  sh -c "ss -tnH state established '( sport = :2222 )' | awk '{ print \"  peer \" \$4 }'" ||
  log_error 'Could not reach the container - is it running?'
echo
echo 'Recent sshd events:'
compose logs --tail 200 "${SERVICE}" 2>/dev/null |
  grep -E 'Accepted|Connection closed|Disconnected|Timeout|Received disconnect' |
  tail -10 || echo '  (none)'
