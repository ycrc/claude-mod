---
name: ycrc-storage
description: Use for YCRC cluster filesystem locations, mydirectories, home/project/scratch/PI storage, persistence, quotas, and scratch-retention questions.
---

# YCRC storage

For scratch retention, purge behavior, expiration warnings, temporary-data lifecycle, or attempts to keep scratch files beyond their lifetime, use `ycrc-scratch` as the authoritative skill.

Use this skill whenever a task depends on where files should live or which storage path is appropriate.

- Use `mydirectories` to discover the current user's actual storage paths. Do not guess group-specific paths.
- `~/project` and `~/scratch` are shortcuts in the home directory. On some accounts they lead to the user's own directory, on others to the group directory, with the user's own one level down (`~/project/<netid>`). Check which (`ls -d ~/project/$USER`), or use the paths `mydirectories` prints; suggest the user's own directory for personal work and the group directory only for work the group shares.
- Home is `/home/<netid>`, per person. Project and scratch are per group; quotas (bytes and file counts) are shared by everyone in the group. Check usage with `getquota`.
- `/apps` is centrally managed and read-only.
- Never touch or copy scratch files merely to evade expiration.

## On Bouchet

- Storage is on the Roberts filesystem: `/nfs/roberts/project`, `/nfs/roberts/scratch` and `/nfs/roberts/pi`.
- The home shortcuts `~/project` and `~/scratch` point to the **group** directory (`/nfs/roberts/project/<group>`, `/nfs/roberts/scratch/<group>`). This is deliberate, so users see their group's shared space. The user's own directory is one level down, `~/project/<netid>` and `~/scratch/<netid>` (the paths `mydirectories` prints): suggest those for personal work, and the group directory (for example its `shared` directory) only for work the group shares.
- Bouchet scratch has a 30-day purge.

### In the local-coding-agents sandbox (`YCRC_LOCAL_CODING_AGENTS=1`)

- The general home tree is hidden except for explicitly bound state/software paths and the selected working directory, and writes to unbound container locations may be lost when the session ends.
- A writable project/scratch/PI path must be user-specific: after an authorized group directory, the path must contain the current user's NetID before arbitrary descendants.
- Each group's `shared` directory (`<base>/<group>/shared` under project, PI and scratch) is bound read-only, by design, so agents never modify files the lab shares. Read from it freely; for writing there, give the user the command to run themselves.

For supporting detail, read `references/storage.md`.
