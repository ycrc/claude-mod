# Claude-Mod

This project implements security settings that make claude safer to use on the cluster.

### File system isolation

Claude runs inside an apptainer image that binds only the current working folder, claude-specific directories, and those needed by tools such as conda. This limits what claude can read and exfiltrate by setting hard, OS-level file system boundaries.

### Security policies

The container forces security policies using `/etc/claude-code/managed-settings.json`.

### Reduced prompt fatigue

Claude asks permission for every operation, but the extreme number of permission requests often leads to prompt fatigue. Eventually, users grow tired of carefully scrutinizing every request, increasing the chance that they will approve a malicious or destructive operation.

Prompt fatigue can be reduced by recognizing that, with strong file system isolation, most common operations within the working folder are safe. Prompt fatigue can be reduced by pre-approving most common operations, leaving a smaller number of more important approvals for the user to examine. Claude's built-in `/sandbox` mode uses the same philosophy.

The module implements this idea by setting permission mode to `auto`. This runs every command through a separate classifier that evaluates whether the command is safe. If deemed safe, it runs it without input. This limits approval requests to those that actually need your attention.

### Network isolation

The module restricts common network operations such as `ssh` or `rsync`, but does not have a hard boundary around network access. For example, the agent could simply write and execute a python program to get around any command-specific restrictions. Apptainer does not have out-of-the-box support for url-level filtering. To achieve better network security, Claude would need to be routed through a proxy server. 

## Run the module

```bash
module use /nfs/roberts/scratch/support/bc447/eb/test_install/system/modules/all
module avail claude
module load claude
```

