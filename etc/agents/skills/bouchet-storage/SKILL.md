---
name: bouchet-storage
description: Use for YCRC Bouchet filesystem locations, mydirectories, home/project/scratch/PI storage, persistence, quotas, and scratch-retention questions.
---

# Bouchet storage

Use this skill whenever a task depends on where files should live or which Bouchet storage path is appropriate.

- Use `mydirectories` to discover the current user's actual storage paths. Do not guess group-specific paths.
- Home is `/home/<netid>`, but the coding-agent container intentionally hides the general home tree except for explicitly bound state/software paths and the selected working directory.
- Roberts storage bases are `/nfs/roberts/project`, `/nfs/roberts/scratch`, and `/nfs/roberts/pi`.
- For this coding-agent launcher, a writable project/scratch/PI path must be user-specific: after an authorized group directory, the path must contain the current user's NetID before arbitrary descendants.
- `/apps` is centrally managed and read-only to coding agents.
- Bouchet scratch has a 30-day purge. Never touch/copy files merely to evade expiration.
- Writes to unbound container locations may be ephemeral.

For supporting detail, read `references/storage.md`.
