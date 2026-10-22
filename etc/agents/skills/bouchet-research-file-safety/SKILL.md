---
name: bouchet-research-file-safety
description: Use before deleting, overwriting, moving, renaming, or bulk-cleaning files in a research project, especially raw or original data, results, collaborator-provided files, and anything in data/, results/, or output directories. Not needed for ordinary source edits or clearly disposable intermediates.
---

# Research file safety

Some research files cannot be recreated: original instrument or sequencing data, data received from collaborators, hand-curated tables, and results that have been reviewed, shared, or published. Others are cheap to regenerate. Before a destructive change, decide which kind of file it is.

## Check before destroying

Before deleting, overwriting, truncating, or moving a file that might be irreplaceable, inspect it rather than assuming:

- **Ownership and origin:** `ls -l`, file owner and group, and where it came from (a collaborator's directory, a delivery folder, a download, a script's output). Files owned by another user, or in a group shared space, are not the agent's to remove.
- **Provenance:** Is there a script in the project that produces it? Is it referenced by other scripts, notebooks, or documentation? Is it tracked in Git?
- **State:** modification time and size. A file much older than the surrounding work, or edited by hand, is more likely to be an original.

If it is original data, collaborator-owned, or a result someone may rely on, and the user has not explicitly asked for this change to this file, stop and ask before destroying it.

## Prefer non-destructive alternatives

- Write a new file (`results_v2.csv`, `filtered_<date>.tsv`) rather than overwriting an existing result.
- Fix the producing script and regenerate, rather than editing its output by hand or with a separate "fixer" script; that keeps outputs reproducible from their source.
- Move questionable files to a clearly named holding directory in the user's own space instead of deleting them, when space allows.
- For bulk cleanup, list what would be removed (`find ... -print`) and check the list before deleting.

## Do not slow down routine work

No confirmation is needed for:

- editing source code, scripts, and documents the user asked to change;
- deleting or overwriting intermediates that the current task created, or that a project script regenerates and that are clearly disposable (caches, temporary files, build artifacts, test output);
- cleanup in the user's own space that the user requested, once what is being removed is clear.

These rules never widen access: the launcher's filesystem restrictions, Unix permissions, and read-only mounts still apply. For scratch lifecycle and purge rules, use `bouchet-scratch`.
