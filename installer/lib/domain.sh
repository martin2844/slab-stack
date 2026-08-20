#!/bin/sh

slabctl_domain_name() {
  domain=$(sed -n 's/^SLAB_DOMAIN=//p' "$SLABCTL_ENVIRONMENT_FILE")
  if [ -z "$domain" ] ||
    [ "$(printf '%s\n' "$domain" | wc -l)" -ne 1 ] ||
    ! printf '%s\n' "$domain" |
      grep -Eq '^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$'
  then
    slabctl_error "installed domain is missing or invalid"
    return 1
  fi
  printf '%s\n' "$domain"
}

slabctl_domain_tls_ready() {
  [ "$SLABCTL_ACCESS_MODE" = domain ] || {
    slabctl_error "this installation is not configured in domain mode"
    return 1
  }
  domain=$(slabctl_domain_name) || return 1
  curl \
    --resolve "$domain:443:127.0.0.1" \
    --connect-timeout 5 \
    --max-time 15 \
    --fail \
    --silent \
    --show-error \
    "https://$domain/ready" >/dev/null
}

slabctl_wait_for_domain_tls() {
  attempts=${SLABCTL_DOMAIN_TLS_ATTEMPTS:-15}
  delay=${SLABCTL_DOMAIN_TLS_DELAY_SECONDS:-2}
  attempt=1
  while [ "$attempt" -le "$attempts" ]; do
    slabctl_domain_tls_ready >/dev/null 2>&1 && return 0
    sleep "$delay"
    attempt=$((attempt + 1))
  done
  return 1
}

slabctl_update_verified_domain_state() {
  next_status=$1
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  temporary_state=$SLABCTL_INSTALL_DIRECTORY/config/.install-state.domain.$$
  jq \
    --arg status "$next_status" \
    --arg updatedAt "$now" \
    '.status = $status
     | .updatedAt = $updatedAt
     | .lastKnownGood = {
         status: $status,
         version,
         accessMode,
         publicUrl,
         projectName,
         completedAt: $updatedAt
       }' "$SLABCTL_STATE_FILE" > "$temporary_state" || return 1
  chmod 0600 "$temporary_state"
  mv "$temporary_state" "$SLABCTL_STATE_FILE"
}

slabctl_domain_verify() {
  slabctl_domain_tls_ready || {
    slabctl_error "HTTPS is not ready with a trusted certificate for the configured domain"
    return 1
  }

  next_status=READY_NO_RUNTIME
  if slabctl_codex_status >/dev/null 2>&1; then
    next_status=READY
  fi
  slabctl_update_verified_domain_state "$next_status" || return 1
  domain=$(slabctl_domain_name) || return 1
  echo "HTTPS is verified for https://$domain. Installation status: $next_status"
}
