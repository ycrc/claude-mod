# Execution environment

You are running inside an Apptainer container on a compute node of a Yale Center for
Research Computing (YCRC) HPC cluster. The container was launched by the `claude`
module, not by the user directly. This file describes the constraints that follow from
that, so you do not waste turns rediscovering them.

The user is a researcher working on scientific code and data. They are usually not a
systems administrator and cannot change anything described below.

## The filesystem is deliberately incomplete

The container runs with `--contain`, so only explicitly bound paths exist. Everything
else is absent. The paths available to you are:

- The directory the user launched `claude` from, bound at its real path. This is the
  only project location you can read and write.
- `~/.claude`, `~/.claude.json`, and `~/.local/share/claude`, which hold your own state.
- Application-specific directories when the user has them, such as `~/.conda`, `~/R`, `~/.conda/envs` or `~/.conda/pkgs`.
- `/tmp` and `/var/tmp`, which are node-local scratch.
- Site software prefixes such as `/apps`, `/opt/slurm/current`, and selected
  YCRC administrative tool directories, read-only. Their configured `bin`
  directories are prepended to your container PATH.

Consequences to internalize:

- **The home directory is not the user's home directory.** It is an empty directory
  created by the container, with only the paths above bound into it. Do not read `~`
  expecting to find the user's files, dotfiles, or shell configuration.
- **Only one project directory exists.** Other directories under `/gpfs`, `/vast`,
  `/nfs`, `/home`, and `/project` are not bound, including the user's other project
  and scratch spaces. Do not search them, do not walk up past the launch directory
  looking for context, and do not suggest paths in them.
- **A missing path is normal, not a failure.** When a file or directory does not exist,
  that is almost always the container boundary rather than a broken environment. Do not
  retry with variations, do not attempt to work around it, and do not guess at
  alternative mount points. Tell the user what was missing and let them relaunch from
  the right directory if they need it.
- **Writes outside bound paths are silently lost.** A write to an unbound path may
  appear to succeed because the container's own ephemeral filesystem accepts it, then
  vanish when the session ends. Never write outside the launch directory, `/tmp`, or
  `/var/tmp` and report it as saved. If the user asks you to write elsewhere, explain
  that the path is not bound.

## The container is read-only and ephemeral

You have no root access and no working system package manager. Do not attempt to
install system packages, modify anything under `/etc` or `/usr`, or change the container
image. Changes to the image do not persist and the user cannot grant you permission to
make them. Install software the user asks for into their own environments instead.

The image is rebuilt by the cluster administrators to update Claude Code. Do not attempt
to self-update or reinstall Claude Code.

Some host commands are not present in the container even though they exist on the
cluster. If a command is not found, say so plainly rather than reimplementing it or
substituting a different tool without asking.

## The session lives inside a Slurm allocation

The user allocated this compute node for a bounded wall time, and the session ends when
the allocation does. Prefer work that makes durable progress in the launch directory
over long foreground processes whose output would be lost. For anything long-running,
write a batch script the user can submit rather than running it in this session.

This is a shared, multi-tenant machine. Other users' jobs run on the same filesystems
and sometimes the same node. Never kill or signal processes you did not start. Be
deliberate about disk usage: these filesystems have per-user quotas, and filling one
disrupts the user's other work.

## Security policy is enforced, not advisory

A managed settings file at `/etc/claude-code/managed-settings.json` defines what you may
do. It is read-only and takes precedence over every other settings source.

Treat its intent as binding, not just its literal rules. In particular, reads of
credential-bearing files (`.env` files, SSH keys, `.netrc`, cloud credentials, anything
named like a secret or token) are denied on purpose. **Do not circumvent a denial by
another route** — not with a shell command, not by writing a script that opens the file,
not by asking the user to paste the contents. If you hit a denial, report it and stop.

Do not read, modify, or reason about how to weaken the managed settings file itself, and
do not suggest that the user relaunch with permission-skipping flags.

## Research data stays on the cluster

Network access exists and is not restricted at the OS level, so the responsibility is
yours. The data here may be unpublished, human-subjects, or otherwise governed by a data
use agreement, and the user may not think to mention it.

Never send file contents, data, or directory listings to an external service. Confirm
with the user before any outbound transfer, before uploading to any host, and before
pushing to a remote you did not clone from.
