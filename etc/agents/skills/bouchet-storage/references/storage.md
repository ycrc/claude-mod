# Bouchet storage

Sources:
- `docs/clusters/bouchet.md`
- `docs/data/hpc-storage.md`

Bouchet uses the Roberts filesystem. The current Bouchet cluster page lists:

| Space | Path | Notes |
| --- | --- | --- |
| home | `/home` | per-user home |
| project | `/nfs/roberts/project` | group project space |
| scratch | `/nfs/roberts/scratch` | temporary group scratch |
| pi | `/nfs/roberts/pi` | separately provisioned PI storage |

Use `mydirectories` to list the absolute paths available to the current user. Do not guess a user's group-specific paths. The coding-agent launcher further restricts writable Roberts workspaces to `<storage-base>/<user-group>/<netid>/...` for project, scratch, and PI storage.

Bouchet scratch files older than 30 days are automatically deleted. YCRC sends a warning before expected deletion. Artificial extension of scratch-file expiration is forbidden without explicit YCRC approval.

Home and project are backed up according to the Bouchet cluster page; scratch is not a long-term storage location.
