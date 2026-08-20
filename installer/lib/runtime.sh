#!/bin/sh

slab_assert_non_root_workload() {
  service=$1
  container_id=$2

  if ! process_table=$(docker top "$container_id" -eo pid,user,comm 2>&1); then
    printf 'Could not inspect %s processes: %s\n' "$service" "$process_table" >&2
    return 1
  fi

  if ! printf '%s\n' "$process_table" | awk -v service="$service" '
    NR == 1 { next }
    $3 == "docker-init" || $3 == "tini" { next }
    {
      workload_count += 1
      if ($2 == "root" || $2 == "0") {
        printf "%s workload process %s is running as root.\n", service, $3 > "/dev/stderr"
        root_workload = 1
      }
    }
    END {
      if (workload_count == 0) {
        printf "%s has no workload process behind its init supervisor.\n", service > "/dev/stderr"
        exit 1
      }
      exit root_workload ? 1 : 0
    }
  '; then
    return 1
  fi
}
