---
name: bouchet-handoff
description: Use when the user asks for a handoff, a session summary, or to save progress so work can continue in a new session or another coding agent, and to pick up from an existing HANDOFF.md. Offer it at a natural stopping point in long sessions; never write it unasked.
---

# Session handoff

A handoff note lets a new session, or a different coding agent, continue the work without relying on this session's context. It is written while the full context is still available, so it is more reliable than an automatic context compaction.

## Writing a handoff

Write it only when the user asks. Use one file, `HANDOFF.md`, in the working directory; if it exists, update it rather than adding another. Keep it short and factual:

- **Goal:** what the work is for, in a sentence or two.
- **State:** what is done, and what works and what does not.
- **Files changed:** paths, with one line each on what changed.
- **Commands and tests:** what was run and the result (pass/fail, key numbers). Note anything that was not verified.
- **Slurm jobs:** IDs of running or pending jobs, what they do, and where their output goes.
- **Environment:** modules (with versions), Conda or renv environments, and any `--bind` directories the work depends on.
- **Next steps:** unfinished work, open questions, and decisions waiting on the researcher.

Do not include secrets, tokens, or the contents of large files; point to paths instead.

## Resuming from a handoff

When a session starts with `HANDOFF.md` present and the user wants to continue, read it first, check its claims against the current files and `squeue --me` before relying on them, and then carry on from the next steps.
