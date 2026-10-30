---
name: bouchet-storage
description: Use for YCRC Bouchet filesystem locations, mydirectories, home/project/scratch/PI storage, persistence, quotas, and scratch-retention questions.
---

# Bouchet storage

For Bouchet scratch retention, purge behavior, expiration warnings, temporary-data lifecycle, or attempts to keep scratch files beyond their lifetime, use `bouchet-scratch` as the authoritative skill.

Use this skill whenever a task depends on where files should live or which Bouchet storage path is appropriate.

- Use `mydirectories` to discover the current user's actual storage paths. Do not guess group-specific paths.
- The home shortcuts `~/project` and `~/scratch` point to the **group** directory (`/nfs/roberts/project/<group>`, `/nfs/roberts/scratch/<group>`). This is deliberate, so users see their group's shared space. The user's own directory is one level down, `~/project/<netid>` and `~/scratch/<netid>` (the paths `mydirectories` prints): suggest those for personal work, and the group directory (for example its `shared` directory) only for work the group shares.
- Home is `/home/<netid>`, but the coding-agent container intentionally hides the general home tree except for explicitly bound state/software paths and the selected working directory.
- Roberts storage bases are `/nfs/roberts/project`, `/nfs/roberts/scratch`, and `/nfs/roberts/pi`.
- For this coding-agent launcher, a writable project/scratch/PI path must be user-specific: after an authorized group directory, the path must contain the current user's NetID before arbitrary descendants.
- `/apps` is centrally managed and read-only to coding agents.
- Each group's `shared` directory (`<base>/<group>/shared` under project, PI and scratch) is bound read-only into coding-agent sessions, by design, so agents never modify files the lab shares. Read from it freely; for writing there, give the user the command to run themselves.
- Bouchet scratch has a 30-day purge. Never touch/copy files merely to evade expiration.
- Writes to unbound container locations may be ephemeral.

For supporting detail, read `references/storage.md`.
