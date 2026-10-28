# Onboarding checklist and tutorial

## Checklist template

Create `BOUCHET-ONBOARDING.md` in the working directory from this template once the user has told you their goal. Fill in what you learn; mark steps `[x]` done, `[ ]` open, `[-]` skipped (say why). Keep notes to one line each, and record anything only the user can do as "You:".

```markdown
# Bouchet onboarding: <netid>

Goal: <what they want to do on Bouchet, in their words>
Mode: guided | tutorial
Started: <date>   Last updated: <date>

- [ ] 1. Access and accounts: groups <...>; default Slurm account <...>; connects via <portal/SSH>
- [ ] 2. Storage: project <path>; scratch <path>; quota checked (<usage>); knows the 30-day scratch purge
- [ ] 3. Where work runs: login vs compute; salloc vs sbatch; partitions for their goal: <...>
- [ ] 4. Software: <modules or Conda environment for their goal>
- [ ] 5. First job: job <id> on <partition> <state>; efficiency reviewed
- [ ] 6. Web portal: <apps that fit their goal>
- [ ] 7. Moving data: <how their data gets to Bouchet, or skipped>
- [ ] 8. AI tools: <if relevant, or skipped>
- [ ] 9. Help and training: support email, office hours, Intro to HPC
- [ ] 10. First real task: <next step and the skill or doc for it>

Notes:
- You: <anything only the user can do, e.g. upload an SSH key, request a group change>
```

When resuming, read the file, give a two-line summary of what's done, and continue with the first open step. Update "Last updated" whenever you change it.

## Tutorial mode

In tutorial mode the user types the commands. For each step: say what the step teaches, give the command or task, wait for their result, check it (their pasted output, or a command or tool you run to confirm), explain what it shows, then mark the checklist.

Use YCRC's Intro to HPC material as the curriculum, so what they learn matches YCRC's workshops:

- **Tutorial page:** https://docs.ycrc.yale.edu/resources/intro_to_hpc_tutorial/ (slides, cheat sheet).
- **Exercises:** https://github.com/ycrc/Intro-to-HPC. A copy is on Bouchet at `/apps/data/training/Intro-to-HPC` (`workshop_examples/`, `extra_examples/`, `office_hour_examples/`).

The exercises' sections map onto the checklist:

| Exercise section | Checklist step | Notes for Bouchet |
| --- | --- | --- |
| Navigating and using HPC (pwd, ls, cd, nano, cp, mv, rm) | before 1 | Skip if they already use a Linux shell. |
| Transfer data (`ssh transfer`, copy `/apps/data/training/Intro-to-HPC` to `~/project/workshop`) | 7 | On Bouchet the data path is `/apps/data/training`. |
| Understanding quotas (`getquota`) | 2 | In an agent session, run it as `srun --overlap --ntasks=1 getquota` (see `bouchet-essentials.md`). |
| Running Python (`salloc`, `module load Python`, the interactive example) | 3, 4 | `module load Python` is fine for these plain scripts; for packages, use Conda (next row). |
| Installing packages with Miniconda (`conda create -n myenv ...`) | 4 | Follows `bouchet-conda`. |
| Conda with Jupyter in the portal (`notebook`, `ycrc_conda_env.sh update`) | 6 | Follows `bouchet-jupyter`, including Develop -> Restart Web Server. |

Then do the first job (step 5) with `first-job.sh` from `bouchet-essentials.md`: the user writes it from the template, you check it with `sbatch --test-only` (or `check_job_script` in Open WebUI), they submit it, and you read the result together.

Keep the pace theirs: one step at a time, and no long blocks of commands they haven't asked for.
