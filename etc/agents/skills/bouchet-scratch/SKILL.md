---
name: bouchet-scratch
description: Use for Bouchet scratch storage, including the 30-day purge policy, temporary working data, purge warnings, cleanup, migration to persistent storage, quotas, and prohibited artificial extension of file expiration.
---

# Bouchet scratch storage

Use this skill whenever a Bouchet workflow involves `/nfs/roberts/scratch`, scratch retention, purge warnings, temporary data, or keeping scratch files beyond their normal lifetime.

## Scratch is temporary — 30-day purge

- Bouchet scratch is temporary working storage, not long-term or archival storage.
- **Any file in Bouchet scratch older than 30 days is automatically deleted.**
- YCRC sends a weekly warning about files expected to be deleted the following week.
- Scratch quota is shared by the research group.
- If YCRC storage becomes constrained, users may be asked to delete scratch files even before the normal time limit.
- Scratch is not backed up. Important or irreplaceable data must have a persistent copy elsewhere.

## Do not artificially extend expiration

**Artificial extension of scratch file expiration is forbidden without explicit approval from YCRC.**

Do not recommend, write, or execute workflows whose purpose is to defeat the scratch purge policy, including:

- `touch` or similar commands used to refresh timestamps solely to prevent expiration;
- changing file modification times or other timestamps to make old data appear newer;
- periodically rewriting files without a scientific/computational need merely to reset their age;
- copying, moving, renaming, repacking, recompressing, or recreating unchanged data solely to obtain a new expiration window;
- scheduled jobs, cron-like workflows, agents, or scripts whose purpose is to keep scratch data alive indefinitely;
- any equivalent timestamp or metadata manipulation intended to evade the retention policy.

Do not help optimize or automate such a workaround. If a user asks how to keep scratch data past the retention period, explain that scratch is temporary and help them move data that must be retained to appropriate persistent storage instead.

If there is a legitimate exceptional need to extend scratch lifetime, the documented policy requires **explicit YCRC approval**. Direct the user to YCRC at `research.computing@yale.edu`.

## Appropriate scratch use

Scratch is appropriate for:

- temporary inputs staged for computation;
- intermediate files;
- working copies of data whose permanent copy exists elsewhere;
- large transient outputs that can be regenerated;
- high-volume job I/O that does not require long-term retention.

A useful workflow is:

1. Keep the authoritative/permanent copy in appropriate persistent storage.
2. Stage the working data into Bouchet scratch.
3. Run the computation.
4. Copy results that must be retained to appropriate persistent storage.
5. Delete temporary/intermediate scratch data when it is no longer needed rather than relying on automatic purge.

Use `bouchet-storage` to choose among home, project, PI, scratch, and other authorized storage.

## Quotas and file counts

Scratch limits both bytes and file count and is shared by the research group. Use:

```bash
getquota
```

to inspect current YCRC storage usage and limits.

If a quota is full, do not evade it by moving data among scratch paths or creating artificial copies. Identify unneeded temporary data, reduce unnecessary file counts where scientifically appropriate, or move data that must persist to suitable storage.

## Agent behavior

When operating in scratch:

- normal scientific writes that naturally update a file are fine;
- normal creation of new intermediate/output data is fine;
- deleting temporary data at the user's request is fine;
- do not treat ordinary computation as a policy violation merely because it changes modification times;
- the prohibited behavior is **artificially changing/recreating data for the purpose of extending its scratch lifetime**.

For the YCRC-derived policy text and source notes, read `references/scratch-ycrc.md`.
