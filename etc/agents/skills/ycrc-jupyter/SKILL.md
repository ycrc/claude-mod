---
name: ycrc-jupyter
description: Use for Jupyter Notebook and JupyterLab on YCRC clusters, including the Open OnDemand Jupyter app, making a Conda environment appear in its menu (notebook package, ycrc_conda_env.sh update, Restart Web Server), the ycrc_default environment, notebook root directory, kernels, and running notebooks non-interactively in batch jobs with Papermill.
---

# YCRC Jupyter

YCRC provides Jupyter Notebook and JupyterLab through the **Jupyter** interactive app in the Open OnDemand (OOD) web portal. The user launches it from the portal (Interactive Apps menu), picks a Conda environment from a drop-down, requests CPUs, memory, GPUs and time, and connects. An agent cannot launch or click through OOD; it prepares the environment and tells the user what to do in the portal. Public guide: https://docs.ycrc.yale.edu/clusters-at-yale/access/ood-jupyter/

Do not start a Jupyter server inside the agent session or recommend SSH tunnels for it; the OOD app is the supported way to run interactive notebooks.

## Environments for the Jupyter app

The drop-down offers `ycrc_default` (built automatically the first time the user selects it) and the user's own Conda environments. For an environment to work in the app and appear in the menu:

- Create it with `-n`/`--name`, **never `--prefix`**. The app only finds environments under the Conda envs directory (`~/.conda/envs`, which may be a symlink to project storage).
- It must contain the **`notebook`** package; without it the environment fails in the app. Add `jupyterlab` too if the user wants the app's **Start JupyterLab** option.
- Follow the `ycrc-conda` skill for everything else (an interactive session on a compute node, `miniconda` as the only software module, Conda before pip, large environments in a larger interactive session).

Create a new environment, or add Jupyter to an existing one (Python packages come from `uv`, as in `ycrc-conda`; if an older environment has no `uv`, run `conda install -y uv` in it first):

```bash
module load miniconda && conda create -y -n notebook_env python=3.12 uv \
  && conda activate notebook_env && uv pip install notebook numpy pandas matplotlib
```

```bash
module load miniconda && conda activate notebook_env && uv pip install notebook
```

Then the menu must be refreshed, in two steps:

1. **Update the menu lists with `ycrc_conda_env.sh update`.** It rewrites the lists in `~/ondemand/` from every environment that has `bin/jupyter-notebook` or `bin/jupyter-lab`. Run it (or as the cluster notes below say for the agent's environment), then confirm the environment is listed:

   ```bash
   ycrc_conda_env.sh update && grep '^notebook_env:' ~/ondemand/conda-jupyter-env-list.txt
   ```

   A listed environment appears as `notebook_env:true` (JupyterLab available) or `notebook_env:false` (Notebook only). In a normal terminal the user can simply run `ycrc_conda_env.sh update`.
2. **Tell the user to restart the portal's web server:** in the OOD portal, **Develop -> Restart Web Server**. The new environment does not appear in the drop-down until they do.

## On Bouchet

- In the Papermill batch script below, use `#SBATCH --partition=day` for the CPU partition.

### In the local-coding-agents sandbox (`YCRC_LOCAL_CODING_AGENTS=1`)

- Inside the agent session `~/ondemand` is not mounted, so running `ycrc_conda_env.sh update` there appears to succeed but its output is lost when the session ends. Run it as a step of the session's own Slurm allocation instead, which runs outside the sandbox, updates the real lists and prints straight back; then confirm the environment is listed:

  ```bash
  srun --overlap --ntasks=1 bash -c \
    "ycrc_conda_env.sh update && grep '^notebook_env:' ~/ondemand/conda-jupyter-env-list.txt"
  ```

## Root directory and data

The app starts in the user's home directory. Project and scratch storage are reached through their symlinks in home. To browse another location from Jupyter, such as purchased storage, the user creates a symlink to it in their home directory.

## Running notebooks as batch jobs

To run a notebook non-interactively (for long runs, or many parameter sets), use [Papermill](https://papermill.readthedocs.io/), which executes every cell and saves outputs and figures in a new notebook. Install it into the notebook's environment:

```bash
module load miniconda && conda activate notebook_env && uv pip install papermill
```

Then run the notebook in a batch job sized for the work (see `ycrc-slurm`, and `ycrc-gpu` for GPU notebooks):

```bash
#!/bin/bash
#SBATCH --partition=<cpu-partition>
#SBATCH --cpus-per-task=1
#SBATCH --time=6:00:00

module reset
module load miniconda
conda activate notebook_env
papermill analysis.ipynb analysis-output.ipynb -p alpha 0.5
```

`-p NAME VALUE` overrides variables in the notebook's cell tagged `parameters`. For many parameter sets, use a job array or dSQ (`ycrc-dsq-arrays`) with one Papermill run per task, each writing its own output notebook.

## Troubleshoot

- **Environment missing from the drop-down:** check that it was created with `-n`, contains `notebook` (`ls ~/.conda/envs/<env>/bin/jupyter-notebook`), that the menu-list check above shows it, and that the user restarted the web server.
- **Jupyter does not start:** the environment lacks `jupyter-notebook`, or `jupyter-lab` when **Start JupyterLab** is checked; install `notebook` (and `jupyterlab`), refresh the menu, and relaunch.
- **Kernel dies or restarts:** usually memory. Check the session with Jobstats (`ycrc-job-troubleshooting`) and have the user relaunch with more memory in the app form.
- **Papermill fails with `NoSuchKernel`:** the notebook was saved with a kernel name that does not exist in this environment (common when it names another Conda environment). Add `-k python3` to run it with the activated environment's Python.
- **Import works in a terminal but not in the notebook:** the notebook is using a different environment; relaunch the app with the environment that has the package, or install the package into the one the notebook uses.
