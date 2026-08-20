# Service runtime contract

All images included in a stable Slab stack release must satisfy this contract.

## Common

- Support `linux/amd64` and `linux/arm64`.
- Run as a non-root user.
- Write durable state only to the documented `/data` or runtime-auth volume.
- Exit non-zero on invalid configuration before listening.
- Handle SIGTERM and stop within the Compose grace period.
- Expose `/health` for liveness and `/ready` for schema readiness.
- Never require a public host port.
- Never log secret values or a complete environment dump.
- Accept sensitive configuration through a `*_FILE` variable.
- Reject simultaneous `NAME` and `NAME_FILE` configuration.
- Provide a deterministic, idempotent migration command.
- Include OCI source, revision, version, created, and license labels.

## Ports and state

| Service | Container port | Durable state |
| --- | ---: | --- |
| Slab Agents | 3009 | `/data/slab-workspace.db` and control-plane key material |
| Slab Work API | 6970 | `/data/slab.db` shared with Work MCP |
| Slab Work MCP | 6969 | `/data/slab.db` shared with Work API |
| Slab Docs | 6980 | `/data/slab-docs.db` |
| Slab Email | 6981 | `/data/slab-email.db` |
| Slab Runner | 6990 | `/var/lib/slab-runner/codex` |

## Internal URLs

The stack seeds these server-only values:

```text
WORK_MCP_URL=http://slab-mcp:6969/mcp
DOCS_MCP_URL=http://slab-docs:6980/mcp
RUNNER_URL=http://slab-runner:6990
SLAB_EMAIL_URL=http://slab-email:6981
CONTROL_PLANE_INTERNAL_URL=http://slab-agents:3009
```

`SLAB_PUBLIC_URL` is separate. It is the canonical browser/security origin and
must never replace the internal callback URL.

## Secret files

| Secret | Consumer variables |
| --- | --- |
| Work API key | `TRACKER_API_KEY_FILE` |
| Docs API key | `DOCS_API_KEY_FILE` |
| Runner token | `RUNNER_TOKEN_FILE` |
| Email admin key | `SLAB_EMAIL_ADMIN_KEY_FILE` |
| Email master key | `SLAB_EMAIL_MASTER_KEY_FILE` |
| Session signing secret | `SLAB_SESSION_SECRET_FILE` |

The file contains the raw value followed by an optional final newline. Services
trim exactly that final newline, reject an empty value, and do not expose the
path or value through public settings.

## Readiness

`/health` must remain useful even when an optional external provider is down.
For example, Codex being signed out or an Email account being unreachable does
not make the Runner or Email process dead. Those conditions appear in detailed
runtime/integration status.

## Migration lifecycle

The stack runs one migration owner per database before starting its writers:

```text
migration job succeeds
        │
        └── writers start with startup migrations disabled
```

A migration failure prevents new writers from starting. It does not delete or
automatically roll back the database.

