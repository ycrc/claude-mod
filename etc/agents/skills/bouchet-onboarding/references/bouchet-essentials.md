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
  - Open WebUI: ask the user to run `groups` and `slurm_checkup.sh` in a terminal (in the portal: **Clusters -> Shell Access**).
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

- **Check:**
  - Agent: `mydirectories` (their real paths), plus `srun --overlap --ntasks=1 getquota`.
  - Open WebUI: `storage_quota`, `list_directory`.
- **Home** (`/home/<netid>`; `mydirectories` shows its underlying path, `/nfs/roberts/home/<netid>`, but call it `/home/<netid>`): 125 GiB, backed up. Configuration files, scripts, small files.
- **Project** (`/nfs/roberts/project/<group>/<netid>`, shortcut `~/project`): 4 TiB per group, shared with the group's quota, backed up. Data and results to keep.
- **Scratch** (`/nfs/roberts/scratch/<group>/<netid>`, shortcut `~/scratch`): 10 TiB per group, **not backed up**, files older than **30 days are deleted automatically** (a weekly email warns about files due for deletion). Temporary and intermediate files only.
- **PI groups:** have shortcuts `~/project_pi_<pi>` and `~/scratch_pi_<pi>`.
- `getquota` shows usage for the group and per user.
- Details: `bouchet-storage`, `bouchet-scratch`.

## 3. Where work runs

- **Login nodes:** for editing files, managing jobs and light commands only. Anything computational runs on compute nodes through Slurm.
- **Interactive vs batch:**
  - Interactive: `salloc --partition=devel --cpus-per-task=1 --mem=4G --time=2:00:00`, then work in that shell.
  - Batch: write a script, then `sbatch script.sh`; output goes to a file.
- **Check partitions live:**
  - Agent: `sinfo -o "%P %l %D %G"` for partitions, time limits, nodes and GPUs.
  - Open WebUI: `partition_status`.
- **Partitions as documented** (confirm live; offer only what the user can use):
  - `day`: the default; up to 1 day.
  - `devel`: testing and interactive work; up to 6 hours, 4 CPUs, 60G, 2 jobs per user.
  - `week`: up to 7 days.
  - GPUs: `gpu`, `gpu_rtx6000`, `gpu_h100`, `gpu_h200`, `gpu_b200`, up to 2 days, request with `--gpus=1`; interactive GPU work uses `gpu_devel`.
  - `scavenge`: free spare capacity, but jobs can be preempted.
  - Not for normal users: `admintest`. `priority*` costs Priority Tier credits.
- **Ask for what the job needs:** CPUs, memory, time. Small, accurate requests start sooner.
- Details: `bouchet-slurm`, `bouchet-gpu`, `bouchet-parallel`.

## 4. Software

- **Find software:**
  - Agent: `module spider <name>` (all versions), then `module spider <name>/<version>` for how to load it.
  - Open WebUI: `software_search`.
- Load in the same command that uses it: `module load <name>/<version> && <command>`. Start a fresh setup with `module reset`, never `module purge`.
- **Python:** for anything beyond the standard library, use Conda: `module load miniconda && conda create -n myenv python numpy pandas`, then `module load miniconda && conda activate myenv && python script.py`. Plain `module load Python` works for simple scripts.
- **R:** modules or Conda; RStudio in the web portal.
- Details: `bouchet-modules`, `bouchet-conda`, `bouchet-r`.

## 5. First job

Test script (`first-job.sh`):

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

- **Jupyter:** Conda environments need the `notebook` package and registration; see `bouchet-jupyter`.
- **RStudio Server**, **VS Code**, **Remote Desktop**.
- **Open WebUI:** a chat assistant on the YCRC-hosted model, with read-only tools for the user's jobs and files.
- **Shell access, file browser and job viewer** are in the portal's menus.

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
