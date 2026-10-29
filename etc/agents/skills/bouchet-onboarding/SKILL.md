---
name: bouchet-onboarding
description: Use when a user is new to YCRC's Bouchet cluster or asks how to get started (logging in, where to put files, which resources or partition to use, running a first job, the Open OnDemand web portal, getting help), when they want to be taught the basics step by step, or to resume an onboarding checklist (BOUCHET-ONBOARDING.md). Also offer it, briefly and once, when a request suggests the user is new to Bouchet.
---

# Bouchet onboarding

Help a new user get working on Bouchet: check their real setup, explain what matters, do the safe parts, and leave them with a checklist they can resume. This skill is an entry point: it covers the essentials briefly and routes details to the topic skills.

## When to use, and offering it

- Use it when the user says they are new, asks how to get started, or asks to be taught the basics.
- Offer it when a request suggests the user is new to Bouchet, for example: they ask what resources to use, guess paths (`/project`, `/scratch`), try heavy work on a login node, have no Conda environments, or have no job history. Offer **once per session, in one sentence, alongside** doing what they asked; never hold their task hostage to onboarding. If they decline, drop it.
- Users are trusted researchers. Be welcoming and practical; don't lecture about rules they haven't broken.

## Start with their goal

Before the checklist, ask what they want to do on Bouchet (for example: run Python or R analyses, train models on GPUs, use specific software, work in notebooks). Order the steps around it: someone training models needs Conda and GPUs early; an R user needs RStudio in the portal. Skip steps that don't apply, and say so in the checklist.

## Two modes

- **Guided (default):** check the user's actual state, explain each finding in plain language, do what is safe to do for them (run checks, submit the tiny test job, create the checklist file), and give them the rest as exact instructions.
- **Tutorial (when they ask to learn by doing, e.g. "teach me", "step by step"):** the user runs each step themselves; you explain what it does, then check their result (their output, their job with `sacct`, their script with `sbatch --test-only` or `check_job_script`). Use YCRC's Intro to HPC material as the curriculum; see `references/onboarding-checklist.md`.

The user can switch modes at any time.

## Where the work happens

Onboarding work (the checklist, the test job, practice files) lives in a new directory in the user's **project** storage, for example `~/project/bouchet-onboarding` (the real path is under `/nfs/roberts/project/<group>/<netid>`; see `mydirectories`). Home is small and meant for configuration and scripts, so don't put work there; setting this up is also the first practical lesson about where things belong on Bouchet.

- **Coding agents** can only write in the directory the session was started in. Check it (`pwd -P`). If it is not under `/nfs/roberts/project/`, explain why before creating any files and ask the user to restart there: `mkdir -p ~/project/bouchet-onboarding && cd ~/project/bouchet-onboarding`, then start the agent again. A checklist from an earlier session is found there.
- **Open WebUI** cannot write to the user's directories: give them the `mkdir` command and put files in `~/openwebui-outputs` with the `cp` command to move them into that directory.

## The checklist file

Keep progress in `BOUCHET-ONBOARDING.md` in that project directory, so a later session, or another tool, can pick up where they left off.

- At the start, look for it in the working directory. If it exists, summarize what is done and continue from the first open step.
- Otherwise create it from the template in `references/onboarding-checklist.md` once the user has told you their goal, and tell them it exists and what it is for (one sentence).
- Update it as steps finish: `[x]` done, `[ ]` open, `[-]` skipped (with the reason), plus a one-line note of anything they must do themselves.
- In Open WebUI, offer it as a file in `~/openwebui-outputs` with the `cp` command into their onboarding directory, or keep the checklist in the chat.

## The steps

For each step: **check** their real state, **explain** what it means for them, **fix or teach**, then **mark** the checklist. Exact commands, tools and facts are in `references/bouchet-essentials.md`; read it before giving any Bouchet-specific fact.

Give every step its turn. Don't fold the remaining steps into a closing summary unless the user asks to speed up, and never drop one silently: if a step doesn't apply, say so in a sentence and mark it `[-]` with the reason.

1. **Access and accounts:** their groups and Slurm accounts (PI groups are `pi_<pi-netid>`); how they connect (portal, SSH with Duo).
2. **Storage (take your time here):** this is where new users most often go wrong, so go beyond a list of paths. Show their real directories and quota, then explain each space with their own numbers: what belongs in home, project and scratch, which quotas are shared with the whole group (bytes *and* file counts), what is backed up, the 30-day scratch purge, sharing with their lab, and recovering deleted files. Suggest a layout for their goal (code and data in project, large intermediate files in scratch, results copied back to project) and check they can say where they would put their own data before moving on.
3. **Where work runs:** login nodes versus compute nodes; interactive (`salloc`) versus batch (`sbatch`); choosing a partition.
4. **Software:** finding modules; Python and R through Conda.
5. **First job:** a tiny test job, then reading its result and efficiency.
6. **Web portal:** the Open OnDemand apps that fit their goal. When they open one (for example Jupyter with their environment), make it hands-on: have them use it for a minute (see `references/bouchet-essentials.md`) and close it when done, rather than treating the launch as the end of the step.
7. **Moving data:** the transfer node and Globus, if they have data elsewhere.
8. **AI tools:** coding agents, Open WebUI, and `module load ycrc-llm` for their own scripts, if relevant.
9. **Getting help and training.**
10. **Their first real task:** hand off to the topic skills below.

## Route details to the topic skills

Keep onboarding short; when a step needs depth, use the skill for it:

- Storage and quotas: `bouchet-storage`; scratch purge: `bouchet-scratch`
- Modules: `bouchet-modules`; Python and Conda: `bouchet-conda`; R: `bouchet-r`
- Notebooks and the portal's Jupyter app: `bouchet-jupyter`
- Jobs and partitions: `bouchet-slurm`; problems with jobs: `bouchet-job-troubleshooting`
- GPUs: `bouchet-gpu`; many similar jobs: `bouchet-dsq-arrays`; parallel work: `bouchet-parallel`
- Their research data and analysis: `bouchet-research-file-safety`, `bouchet-research-analysis`

## Facts that are easy to get wrong

Do not answer these from general HPC knowledge; they differ on Bouchet:

- The login host is `bouchet.ycrc.yale.edu` (not `bouchet.hpc.yale.edu`), with SSH keys uploaded at `https://sshkeys.ycrc.yale.edu/` and Duo.
- Storage is per group under `/nfs/roberts/...`, not `/project` or `/scratch`. Get the user's real paths from `mydirectories`; never guess them.
- Python is used through `module load miniconda` and Conda environments; never invent module names (`python/3.11` does not exist). Find real names with `module avail <name>` or `software_search`.
- Partition limits change; read them live (`sinfo`, `partition_status`) instead of quoting from memory. Offer only partitions the user can use: not `admintest`, and not `priority*` unless they have Priority Tier credits.
- The portal's Job Composer is disabled on Bouchet (it confused users). Don't mention it; batch jobs are submitted with `sbatch` from a shell.

## What you can and cannot do

- **Coding agents:** you can run commands, submit jobs, and write the checklist in the working directory. Some commands do not work inside the agent's sandbox (see `references/bouchet-essentials.md`); run those with `srun --overlap --ntasks=1 <command>`, a step of the session's own allocation that runs outside it.
- **Open WebUI:** use the read-only Bouchet tools (`storage_quota`, `recent_jobs`, `my_jobs`, `job_details`, `job_efficiency`, `partition_status`, `software_search`, `check_job_script`, `list_directory`). You cannot submit jobs; give the user the job script and the command, then check the job with the tools.
- **Never possible for you:** uploading SSH keys, approving Duo, changing groups, or clicking in the web portal. Tell the user exactly what to do, with the link.
