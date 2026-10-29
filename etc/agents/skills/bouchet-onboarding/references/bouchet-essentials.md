# Bouchet essentials for onboarding

Facts and checks for each onboarding step. **Agent** = command in a coding-agent session; **Open WebUI** = the read-only Bouchet tool to use instead. Prefer what a check shows over anything written here.

## Sandbox caveats (coding agents)

Inside the agent's sandbox some commands give wrong or no results. Run those as a step of the session's own Slurm allocation, which runs outside the sandbox and prints straight back:

- `groups` and `id -Gn` show only `<netid> nobody`. Use `srun --overlap --ntasks=1 groups`.
- `getquota` fails ("missing venv"). Use `srun --overlap --ntasks=1 getquota`.
- The home shortcuts (`~/project`, `~/project_pi_*`, ...) are not visible; get real paths from `mydirectories`.
- `slurm_checkup.sh`, `mydirectories`, `sinfo`, `sacct`, `seff`, `jobstats`, `module` and `sbatch` work normally.

## 1. Access and accounts

- **Check:**
  - Agent: groups (see above) and `slurm_checkup.sh`, which lists their Slurm accounts and marks the default.
  - Open WebUI: ask the user to run `groups` and `slurm_checkup.sh` in a terminal (in the portal: **Bouchet Shell Access** in the top menu bar opens one).
- **Groups:** the primary group is the user's NetID; lab membership shows as `pi_<pi-netid>`. If the lab group is missing, the PI or the user requests it with the Group Change form: https://research.computing.yale.edu/group-change
- **New accounts:** request at https://research.computing.yale.edu/account-request; the PI confirms by email; creation takes about 1-2 business days and requires Yale's cybersecurity awareness training.
- **Connecting:**
  - Web portal: https://ood-bouchet.ycrc.yale.edu (no SSH setup needed).
  - SSH from their own computer:
    1. Create a key with a passphrase: `ssh-keygen`.
    2. Upload the public key at https://sshkeys.ycrc.yale.edu/; it can take up to 10 minutes to become active.
    3. Connect: `ssh <netid>@bouchet.ycrc.yale.edu`.
  - Duo two-factor approval is required. Off campus, connect to the Yale VPN first.

## 2. Storage

Spend real time on this step; misplaced data, a full group quota, or results lost to the scratch purge are the most common new-user problems.

- **Check, and walk through their own output line by line:**
  - Agent: `mydirectories` (their real paths), `srun --overlap --ntasks=1 getquota`, and `ls -l ~/.conda` (where Conda environments are stored).
  - Open WebUI: `storage_quota`, `list_directory`.
  - In `getquota`, explain the group summary versus their personal usage, usage versus quota for both **bytes and file counts**, and the `Backup` and `Purged` columns. Read the limits from their output; don't quote numbers from memory.

| Space | Path (shortcut) | Quota | Backed up | Use it for |
| --- | --- | --- | --- | --- |
| Home | `/home/<netid>` (`mydirectories` shows `/nfs/roberts/home/<netid>`; call it `/home/<netid>`) | 125 GiB and 500,000 files, **per person** | Yes | Configuration files, small scripts, notes. Not research data or day-to-day work. |
| Project | `/nfs/roberts/project/<group>/<netid>` (`~/project`) | 4 TiB per **group**, plus a group file-count limit | Yes on Bouchet (confirm in `getquota`'s `Backup` column) | Where work happens: code, data, environments and results to keep. |
| Scratch | `/nfs/roberts/scratch/<group>/<netid>` (`~/scratch`) | 10 TiB per **group**, plus a group file-count limit | **No** | Large temporary and intermediate files. Files older than **30 days are deleted automatically**; a weekly email warns about files due for deletion. Copy anything worth keeping back to project. |

- **Group quotas are shared:** project and scratch quotas (bytes and file counts) are shared by everyone in the group, so one person's millions of small files or forgotten intermediate data can stop the whole lab from writing. `getquota` warns when the group nears a limit.
- **PI groups and sharing:**
  - Members of a lab group also have `~/project_pi_<pi>` and `~/scratch_pi_<pi>` shortcuts.
  - Project and scratch directories are readable by the user's group by default (through the real path, not the shortcut).
  - A lab can keep shared data and reference files in `/nfs/roberts/project/<group>/shared`.
  - Never give the home directory group write permission; it breaks logging in.
- **Conda environments:** `~/.conda/envs` normally points into project storage on Bouchet (check with `ls -l ~/.conda`), so environments count against the group's project quota and file count.
- **Recovering deleted files:** home and project have snapshots covering at least the last 2 days; see https://docs.ycrc.yale.edu/data/backups/ or contact YCRC for restores. Scratch has no snapshots.
- **Suggest a layout for their goal,** for example `~/project/<topic>/` with `code/`, `data/` and `results/`, and large intermediate files under `~/scratch/<topic>/`. Then ask where they would put their own data, and correct gently if needed.
- Details: `bouchet-storage`, `bouchet-scratch`.

## 3. Where work runs

- **Login nodes:** for editing files, managing jobs and light commands only. Anything computational runs on compute nodes through Slurm.
- **Interactive vs batch:**
  - Interactive: `salloc --partition=devel --cpus-per-task=1 --mem=4G --time=2:00:00`, then work in that shell. When a session was only for a one-off task (installing packages, a quick test), tell them to `exit` it afterwards; an idle session keeps holding resources and counts toward their limits. First check the user's `devel` jobs (`squeue -u $USER -p devel -o '%i %C %m %T'`, or `my_jobs`; an open Open OnDemand session counts). `devel` allows 2 jobs and 4 CPUs and 60G **in total**: a third job is rejected, and a request bigger than what is left (for example 4 CPUs while a 2-CPU session runs) waits pending. Size the request to what is left, or use `--partition=day`.
  - Interactive jobs (Open OnDemand sessions and `salloc`) are limited to 4 running at once per user, across all partitions; a fifth waits until one ends. Newcomers often leave portal sessions open, so suggest closing ones they no longer use.
  - Batch: write a script, then `sbatch script.sh`; output goes to a file.
- **Check partitions live:**
  - Agent: `sinfo -o "%P %l %D %G"` for partitions, time limits, nodes and GPUs.
  - Open WebUI: `partition_status`.
- **Partitions as documented** (confirm live; offer only what the user can use):
  - `day`: the default; up to 1 day.
  - `devel`: testing and interactive work; up to 6 hours; per user, 2 jobs and 4 CPUs and 60G in total across all of them, open Open OnDemand sessions included.
  - `week`: up to 7 days.
  - GPUs: `gpu`, `gpu_rtx6000`, `gpu_h100`, `gpu_h200`, `gpu_b200`, up to 2 days, request with `--gpus=1`; interactive GPU work uses `gpu_devel`.
  - `scavenge`: free spare capacity, but jobs can be preempted.
  - Not for normal users: `admintest`. `priority*` costs Priority Tier credits.
- **Ask for what the job needs:** CPUs, memory, time. Small, accurate requests start sooner.
- Details: `bouchet-slurm`, `bouchet-gpu`, `bouchet-parallel`.

## 4. Software

- **Find software:**
  - Agent: `module avail <name>` lists the versions you can load (`module -r avail '^<name>/'` for only that name); `module show <name>/<version>` shows what one sets.
  - Open WebUI: `software_search`.
- Load in the same command that uses it: `module load <name>/<version> && <command>`. Start a fresh setup with `module reset`, never `module purge`.
- **Python:** use Conda for all Python work (Python and its library modules exist only as dependencies of other software, not for users to load), building the environment in an interactive session (the agent's own session for small environments; see `bouchet-conda`), not in a batch job: `module load miniconda && conda create -y -n myenv python=3.12 uv`, then install packages with `uv` (`module load miniconda && conda activate myenv && uv pip install numpy pandas`) and run with `module load miniconda && conda activate myenv && python script.py`.
- **R:** modules or Conda; RStudio in the web portal.
- Details: `bouchet-modules`, `bouchet-conda`, `bouchet-r`.

## 5. First job

Test script (`first-job.sh`). Keep the first job to this script; don't fold environment builds or real work into it:

```bash
#!/bin/bash
#SBATCH --job-name=first-job
#SBATCH --partition=devel
#SBATCH --cpus-per-task=1
#SBATCH --mem=1G
#SBATCH --time=5:00
#SBATCH --output=first-job-%j.out

hostname
date
echo "Hello from Bouchet"
```

- **Agent, guided:** `sbatch --wait first-job.sh`, then show the output file (if it is not there yet, wait a few seconds: output written on another node can take a moment to appear), `sacct -j <jobid> --format=JobID,State,Elapsed,MaxRSS`, and `seff <jobid>`. Explain each field.
- **Tutorial:** the user writes it; check it with `sbatch --test-only first-job.sh`.
- **Open WebUI:** check the script with `check_job_script`; the user submits it in a terminal with `sbatch first-job.sh`; then read it back with `recent_jobs` / `job_details` / `job_efficiency`.
- **Teach the habit:** look at efficiency (`seff`, `jobstats <jobid>`) after real jobs and right-size the next request. Details: `bouchet-job-troubleshooting`.

## 6. Web portal

https://ood-bouchet.ycrc.yale.edu. Interactive apps run as Slurm jobs with the resources chosen in the form:

- **Jupyter:** Conda environments need the `notebook` package and registration; see `bouchet-jupyter`. Once their environment shows up and they launch a session, walk them through a short hands-on before moving on:
  1. Open a new notebook and pick their environment's kernel (not `ycrc_default`).
  2. Run a check cell, for example `import pandas; print(pandas.__version__)`, so they see their own packages.
  3. Point out that the file browser starts in home, then browse through the `project` shortcut to their onboarding directory and save the notebook there.
  4. When they're done, stop the session from **My Interactive Sessions** (closing the browser tab doesn't stop it), since it holds resources and counts toward their 4 running interactive jobs.
- **RStudio Server**, **VS Code**, **Remote Desktop**.
- **Open WebUI:** a chat assistant on the YCRC-hosted model, with read-only tools for the user's jobs and files.
- **Bouchet Shell Access** in the top menu bar opens a terminal directly, and the **file browser** is in the menus too. Submit batch jobs with `sbatch` from a shell; don't mention Open OnDemand's Job Composer, which is disabled on Bouchet.

## 7. Moving data

- **From their computer:**
  - `rsync -av data/ <netid>@transfer-bouchet.ycrc.yale.edu:<path>/`, or `scp`, using a path from `mydirectories`.
  - Use the transfer node (`transfer-bouchet.ycrc.yale.edu`) rather than the login nodes.
- **Large or remote transfers:** Globus.
- **Small files:** the portal's file browser can upload them.

## 8. AI tools (if relevant)

- **Local coding agents:** `module load local-coding-agents` in an `agent`-partition session (see the AI Coding Agents docs page for the `salloc` line).
- **Open WebUI:** the portal app (see 6).
- **Their own scripts calling the hosted model:** `module load ycrc-llm` sets the endpoint and their key; docs: https://docs.ycrc.yale.edu/ai/hosted-model-api/

## 9. Getting help and training

- **Email:** research.computing@yale.edu (the only YCRC support address).
- **Office hours** on Zoom, Wednesdays and Thursdays (times and link: https://docs.ycrc.yale.edu/#get-help).
- **Intro to HPC tutorial:** https://docs.ycrc.yale.edu/resources/intro_to_hpc_tutorial/ (slides, cheat sheet, exercises).
- **A good help request includes:** NetID, cluster (Bouchet), what they ran and from which directory, the full error message and output file path, job IDs, and the modules or Conda environment loaded.
- **Documentation:** https://docs.ycrc.yale.edu/
