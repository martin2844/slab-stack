#!/bin/sh

slab_validate_release_manifest() {
  manifest_path=$1
  jq -e '
    . as $manifest |
    def exact_keys($expected):
      type == "object" and ((keys | sort) == ($expected | sort));
    def semver:
      type == "string" and
      test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(?:-(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)(?:\\.(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*)?(?:\\+[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*)?$");
    def bounded_https_url:
      type == "string" and length <= 500 and
      (test("[[:space:][:cntrl:]]") | not) and
      (test("%(?![0-9A-Fa-f]{2})") | not) and
      ((try capture("^https://(?<host>[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*\\.[A-Za-z](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(?::(?<port>[0-9]{1,5}))?(?:[/?#][^\\s]*)?$") catch null) as $url |
        $url != null and
        (($url.port // "0") | tonumber) <= 65535);
    (($manifest | keys) - [
      "schemaVersion", "stackVersion", "channel", "releasedAt",
      "minimumSlabctlVersion", "images", "codexVersion",
      "geminiCliVersion", "releaseNotesUrl", "severity",
      "drill", "migrationCompatibility", "dataCompatibility"
    ] | length == 0) and
    .schemaVersion == 1 and
    (.stackVersion | semver) and
    (.channel | IN("development", "candidate", "stable", "drill")) and
    (.releasedAt | type == "string" and
      test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") and
      fromdateiso8601? != null) and
    (.minimumSlabctlVersion | semver) and
    (.codexVersion | type == "string" and length > 0 and length <= 100) and
    ((has("geminiCliVersion") | not) or (.geminiCliVersion | semver)) and
    ((has("releaseNotesUrl") | not) or (.releaseNotesUrl | bounded_https_url)) and
    ((has("severity") | not) or
      (.severity | IN("routine", "security", "critical"))) and
    ((has("drill") | not) or
      (.drill |
        exact_keys(["expectedOutcome", "fault"]) and
        .expectedOutcome == "automatic_rollback" and
        .fault == "agents_image_substituted_with_runner")) and
    (.images | exact_keys(["agents", "work", "docs", "email", "runner"])) and
    (["agents", "work", "docs", "email", "runner"] | all(
      . as $service |
      ($manifest.images[$service] | exact_keys(["ref", "digest", "platforms"])) and
      ($manifest.images[$service].ref | test("^ghcr\\.io/[a-z0-9_.-]+/[a-z0-9_.-]+:(?:v?[0-9]+\\.[0-9]+\\.[0-9]+(?:-[0-9A-Za-z.-]+)?|candidate-[a-f0-9]{40})$")) and
      ($manifest.images[$service].digest | test("^sha256:[a-f0-9]{64}$")) and
      ($manifest.images[$service].platforms |
        type == "array" and length == 2 and
        (unique | length == 2) and
        all(. == "linux/amd64" or . == "linux/arm64"))
    )) and
    (.migrationCompatibility |
      exact_keys(["minimumUpgradeStack", "minimumRollbackStack"]) and
      (.minimumUpgradeStack | semver) and
      (.minimumRollbackStack | semver)) and
    ((has("dataCompatibility") | not) or
      (.dataCompatibility |
        exact_keys(["schemaVersion", "volumes"]) and
        .schemaVersion == 1 and
        (.volumes |
          exact_keys(["agents_data", "work_data", "docs_data", "email_data"]) and
          (["agents_data", "work_data", "docs_data", "email_data"] | all(
            . as $volume |
            ($manifest.dataCompatibility.volumes[$volume] |
              exact_keys(["migrations"]) and
              (.migrations |
                type == "array" and length > 0 and
                . as $migrations |
                ($migrations | unique | length) == ($migrations | length) and
                all(type == "string" and length > 0)))
          )))))
  ' "$manifest_path" >/dev/null 2>&1 || {
    echo "Invalid release manifest: $manifest_path" >&2
    return 1
  }
}

slab_render_image_environment() {
  manifest_path=$1
  for image_mapping in \
    SLAB_AGENTS_IMAGE:agents \
    SLAB_WORK_IMAGE:work \
    SLAB_DOCS_IMAGE:docs \
    SLAB_EMAIL_IMAGE:email \
    SLAB_RUNNER_IMAGE:runner
  do
    environment_name=${image_mapping%%:*}
    service_name=${image_mapping#*:}
    image_reference=$(jq -r --arg service "$service_name" \
      '.images[$service].ref + "@" + .images[$service].digest' \
      "$manifest_path") || return 1
    printf '%s=%s\n' "$environment_name" "$image_reference"
  done
}

slab_render_installation() {
  bundle_root=$1
  install_directory=$2
  manifest_path=$3
  access_mode=$4
  public_url=$5
  domain=$6
  acme_email=$7
  private_bind_ip=$8
  private_port=$9
  # Older slabctl update clients call this target-release helper with nine
  # arguments. Defaulting to deferred identity keeps those clients from
  # claiming the target version before management replacement commits.
  write_identity=${10:-0}
  memory_mode=${SLAB_MEMORY_MODE:-disabled}
  honcho_url=${SLAB_HONCHO_URL:-https://api.honcho.dev}
  honcho_workspace=${SLAB_HONCHO_WORKSPACE_ID:-slab}
  memory_context_tokens=${SLAB_MEMORY_MAX_CONTEXT_TOKENS:-900}

  case "$memory_mode" in
    disabled)
      compose_profiles=
      memory_provider=disabled
      honcho_api_key_file=
      ;;
    managed)
      compose_profiles=
      memory_provider=honcho
      honcho_api_key_file=/run/secrets/honcho_api_key
      ;;
    self_hosted)
      compose_profiles=memory
      memory_provider=honcho
      honcho_url=http://honcho-api:8000
      honcho_api_key_file=
      ;;
    *) echo "Unsupported memory mode: $memory_mode" >&2; return 1 ;;
  esac

  case "$access_mode" in
    private | domain) ;;
    *) echo "Unsupported access mode: $access_mode" >&2; return 1 ;;
  esac
  slab_validate_release_manifest "$manifest_path" || return 1

  if [ -L "$install_directory/config" ]; then
    echo "Refusing symbolic-link config directory: $install_directory/config" >&2
    return 1
  fi
  for managed_path in \
    "$install_directory/compose.yml" \
    "$install_directory/compose.domain.yml" \
    "$install_directory/compose.private.yml" \
    "$install_directory/Caddyfile" \
    "$install_directory/release-manifest.json" \
    "$install_directory/VERSION" \
    "$install_directory/config/install.env" \
    "$install_directory/config/access-mode" \
    "$install_directory/config/install-state.json"
  do
    if [ -L "$managed_path" ]; then
      echo "Refusing symbolic-link managed file: $managed_path" >&2
      return 1
    fi
  done

  # The target release renderer is the compatibility seam used by older
  # slabctl clients. After all non-mutating validation succeeds, ensure secrets
  # introduced by this release exist before Docker Compose evaluates it.
  # shellcheck source=installer/lib/secrets.sh
  . "$bundle_root/installer/lib/secrets.sh"
  slab_prepare_secrets "$install_directory/secrets" || return 1

  mkdir -p "$install_directory/config"
  chmod 0755 "$install_directory" "$install_directory/config"

  cp "$bundle_root/templates/compose.yml" "$install_directory/compose.yml"
  cp "$bundle_root/templates/compose.domain.yml" \
    "$install_directory/compose.domain.yml"
  cp "$bundle_root/templates/compose.private.yml" \
    "$install_directory/compose.private.yml"
  if [ -n "$acme_email" ]; then
    cp "$bundle_root/templates/Caddyfile.domain" "$install_directory/Caddyfile"
  else
    # Match the literal Caddy environment placeholder.
    # shellcheck disable=SC2016
    sed '/^[[:space:]]*email {\$ACME_EMAIL}[[:space:]]*$/d' \
      "$bundle_root/templates/Caddyfile.domain" > "$install_directory/Caddyfile"
  fi
  cp "$manifest_path" "$install_directory/release-manifest.json"

  environment_file=$install_directory/config/install.env
  temporary_environment=$install_directory/config/.install.env.tmp.$$
  {
    printf 'SLAB_PUBLIC_URL=%s\n' "$public_url"
    printf 'SLAB_DOMAIN=%s\n' "$domain"
    printf 'ACME_EMAIL=%s\n' "$acme_email"
    printf 'SLAB_PRIVATE_BIND_IP=%s\n' "$private_bind_ip"
    printf 'SLAB_PRIVATE_PORT=%s\n' "$private_port"
    printf 'COMPOSE_PROFILES=%s\n' "$compose_profiles"
    printf 'SLAB_MEMORY_MODE=%s\n' "$memory_mode"
    printf 'SLAB_MEMORY_PROVIDER=%s\n' "$memory_provider"
    printf 'SLAB_HONCHO_URL=%s\n' "$honcho_url"
    printf 'SLAB_HONCHO_WORKSPACE_ID=%s\n' "$honcho_workspace"
    printf 'SLAB_HONCHO_API_KEY_FILE_IN_CONTAINER=%s\n' "$honcho_api_key_file"
    printf 'SLAB_MEMORY_MAX_CONTEXT_TOKENS=%s\n' "$memory_context_tokens"
    printf '%s\n' 'SLAB_HONCHO_IMAGE=ghcr.io/plastic-labs/honcho:v3.1.0@sha256:b73a8015f9e3ee51525e5b5cb238a915aa47de5107593d81b892213322fa369d'
    printf '%s\n' 'SLAB_HONCHO_DATABASE_IMAGE=pgvector/pgvector:pg15@sha256:a947c45cdc5906a1bc951f20a8709e321256343ee0f251e4ae00b5e7def4e6da'
    printf '%s\n' 'SLAB_HONCHO_REDIS_IMAGE=redis:8.2@sha256:7d1e4ce8b9395088377ab382d1f6cfdbd13b3690795198a0399ab8d683064d6d'
    slab_render_image_environment "$manifest_path"
  } > "$temporary_environment"
  chmod 0644 "$temporary_environment"
  mv "$temporary_environment" "$environment_file"

  if [ "$write_identity" = 1 ]; then
    jq -r '.stackVersion' "$manifest_path" > "$install_directory/VERSION"
  fi
  chmod 0644 \
    "$install_directory/compose.yml" \
    "$install_directory/compose.domain.yml" \
    "$install_directory/compose.private.yml" \
    "$install_directory/Caddyfile" \
    "$install_directory/release-manifest.json" \
    "$install_directory/VERSION"

  printf '%s\n' "$access_mode" > "$install_directory/config/access-mode"
  chmod 0644 "$install_directory/config/access-mode"
}
