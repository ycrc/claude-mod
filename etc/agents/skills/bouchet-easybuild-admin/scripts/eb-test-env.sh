# Source (do not execute), from the root of a ycrc-ebfiles clone, in the SAME
# shell command as the eb calls that follow:
#
#   source /etc/agents/skills/bouchet-easybuild-admin/scripts/eb-test-env.sh && eb ...
#
# Configures EasyBuild for a TEST build with the team's siteconfigs/bouchet.cfg,
# hooks and easyconfigs from this clone, but sends every write under
# software_builds/test-install/: the install tree, the post-build easyconfig
# copy (repositorypath), and source downloads. Setting EASYBUILD_INSTALLPATH is
# the YCRC hooks' testing mode: they skip generation-based install routing and
# the Lmod cache rebuild. Nothing is written to /apps or to easyconfigs/.
if [[ ! -f siteconfigs/bouchet.cfg || ! -f hooks/ycrc_hooks.py ]]; then
    echo "eb-test-env: run from the root of a ycrc-ebfiles clone" >&2
    return 1 2>/dev/null || exit 1
fi
_ebt_here="$(pwd -P)"
_ebt_root="$_ebt_here/software_builds/test-install"
mkdir -p "$_ebt_root/sources" "$_ebt_root/ebfiles_repo" "$_ebt_root/logs" "$_ebt_root/job-output"
# Work in progress stays out of git without touching the shared .gitignore.
grep -qxF 'software_builds/' .git/info/exclude 2>/dev/null || echo 'software_builds/' >> .git/info/exclude

# EasyBuild parses shell output; a missing locale makes every shell warn on
# stderr and breaks that (e.g. its `ulimit -u` check). Fall back to C.UTF-8.
if [[ -n "${LC_ALL:-}" ]] && ! locale -a 2>/dev/null | grep -qix "${LC_ALL//-/}" \
     && ! locale -a 2>/dev/null | grep -qix "$LC_ALL"; then
    export LC_ALL=C.UTF-8
fi
# Start from a clean module environment, as testing() in siteconfigs/bashrc
# does: the site config's detect-loaded-modules=purge otherwise purges other
# loaded modules (e.g. local-coding-agents) and EasyBuild's own PATH with them,
# so `eb --job` submits jobs that cannot find eb.
module purge >/dev/null 2>&1
module load EasyBuild/5.4.0 || { return 1 2>/dev/null || exit 1; }
export EASYBUILD_CONFIGFILES="$_ebt_here/siteconfigs/bouchet.cfg"
export EASYBUILD_ROBOT_PATHS="$_ebt_here/easyconfigs:$EBROOTEASYBUILD/easybuild/easyconfigs"
export EASYBUILD_HOOKS="$_ebt_here/hooks/ycrc_hooks.py"
export EASYBUILD_INSTALLPATH="$_ebt_root"
export EASYBUILD_REPOSITORYPATH="$_ebt_root/ebfiles_repo"
export EASYBUILD_SOURCEPATH="$_ebt_root/sources:/apps/sources"
export EASYBUILD_BUILDPATH="/dev/shm/$USER/eb-build"
# The container's /tmp and /dev/shm vanish when the agent exits; keep logs.
export EASYBUILD_TMP_LOGDIR="$_ebt_root/logs"
# Slurm output of `eb --job` builds, instead of the repository root.
export EASYBUILD_JOB_OUTPUT_DIR="$_ebt_root/job-output"
echo "eb-test-env: test install at $_ebt_root (module use $_ebt_root/modules/all)"
unset _ebt_here _ebt_root
