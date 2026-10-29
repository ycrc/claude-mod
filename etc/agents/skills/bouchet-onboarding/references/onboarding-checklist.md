# Onboarding checklist and tutorial

## Checklist template

Create `BOUCHET-ONBOARDING.md` in the user's onboarding directory in project storage (for example `~/project/bouchet-onboarding`; see "Where the work happens" in `SKILL.md`) from this template once the user has told you their goal. Fill in what you learn; mark steps `[x]` done, `[ ]` open, `[-]` skipped (say why). Keep notes to one line each, and record anything only the user can do as "You:".

```markdown
# Bouchet onboarding: <netid>

Goal: <what they want to do on Bouchet, in their words>
Mode: guided | tutorial
Working directory: <project path>/bouchet-onboarding
Started: <date>   Last updated: <date>

- [ ] 1. Access and accounts: account type <research | course: courseid, portal URL, deletion date>; groups <...>; default Slurm account <...>; connects via <portal/SSH>
- [ ] 2. Storage: home/project/scratch explained with their paths (project <path>, scratch <path>); group quota and file counts checked (<usage>); backups, 30-day scratch purge, lab sharing; layout for their work: <...>
- [ ] 3. Where work runs: login vs compute; salloc vs sbatch; partitions for their goal: <...>
- [ ] 4. Software: <modules or Conda environment for their goal>
- [ ] 5. First job: job <id> on <partition> <state>; efficiency exercise job <id> read with Jobstats (<CPU %>, <memory used of requested>); right-sizing lesson
- [ ] 6. GPUs: <needed? partitions/types for their work; request form; gpu_devel for interactive; idle-GPU rule — or skipped with reason>
- [ ] 7. Web portal: <apps that fit their goal>
- [ ] 8. Moving data: <how their data gets to Bouchet, or skipped>
- [ ] 9. AI tools: <if relevant, or skipped>
- [ ] 10. Help and training: support email, office hours, Intro to HPC
- [ ] 11. First real task: <next step and the skill or doc for it>

Notes:
- You: <anything only the user can do, e.g. upload an SSH key, request a group change>
```

When resuming, read the file, give a two-line summary of what's done, and continue with the first open step. Update "Last updated" whenever you change it.

## Tutorial mode

In tutorial mode the user types the commands. For each step: say what the step teaches, give the command or task, wait for their result, check it (their pasted output, or a command or tool you run to confirm), explain what it shows, then mark the checklist. If part of the result is missing (for example they ran one of two commands), ask for it before moving on.

Use YCRC's Intro to HPC material as the curriculum, so what they learn matches YCRC's workshops:

- **Tutorial page:** https://docs.ycrc.yale.edu/resources/intro_to_hpc_tutorial/ (slides, cheat sheet).
- **Exercises:** https://github.com/ycrc/Intro-to-HPC. A copy is on Bouchet at `/apps/data/training/Intro-to-HPC` (`workshop_examples/`, `extra_examples/`, `office_hour_examples/`).

The exercises' sections map onto the checklist:

| Exercise section | Checklist step | Notes for Bouchet |
| --- | --- | --- |
| Navigating and using HPC (pwd, ls, cd, nano, cp, mv, rm) | before 1 | Skip if they already use a Linux shell. |
| Transfer data (`ssh transfer`, copy `/apps/data/training/Intro-to-HPC` to `~/project/workshop`) | 8 | On Bouchet the data path is `/apps/data/training`. |
| Understanding quotas (`getquota`) | 2 | In an agent session, run it as `srun --overlap --ntasks=1 getquota` (see `bouchet-essentials.md`). |
| Running Python (`salloc`, `module load Python`, the interactive example) | 3, 4 | Teach Conda instead of `module load Python`: Python modules are dependencies of other software, not for users. Do the Miniconda row first and run the example in that environment. |
| Installing packages with Miniconda (`conda create -n myenv ...`) | 4 | Follows `bouchet-conda`: create the environment with `python` and `uv`, then install packages with `uv pip install`. |
| Conda with Jupyter in the portal (`notebook`, `ycrc_conda_env.sh update`) | 7 | Follows `bouchet-jupyter`, including Develop -> Restart Web Server. |

Then do the first job (step 5) with `first-job.sh` from `bouchet-essentials.md`: the user writes it from the template, you check it with `sbatch --test-only` (or `check_job_script` in Open WebUI), they submit it, and you read the result together. Then the efficiency exercise (`efficiency-test.sh` in `bouchet-essentials.md`): they submit it, run `jobstats <jobid>` when it ends and paste the report, and you explain it (in Open WebUI, show the usage graph).

Keep the pace theirs: one step at a time, and no long blocks of commands they haven't asked for.
