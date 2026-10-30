#!/bin/bash
# Gate for the ycrc-easybuild-admin skill. Run from the agent's working
# directory. Exit status:
#    0  OK: YCRC support account, at the root of a ycrc-ebfiles clone
#   10  the account is not in the YCRC "support" group
#   11  the working directory is not the root of a ycrc-ebfiles clone
#
# Group membership is read from the group database (getent), not `id -Gn`:
# inside the coding-agent container supplementary groups appear as "nobody".
# This only decides whether the skill proceeds; it is not a security boundary
# (/apps is read-only inside the container for everyone).
user="$(id -un)"
if ! getent group support | cut -d: -f4 | tr ',' '\n' | grep -qx "$user"; then
    echo "NOT-SUPPORT: account $user is not in the YCRC support group."
    exit 10
fi
here="$(pwd -P)"
top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ "$top" != "$here" || ! -f "siteconfigs/${CLUSTER:-}.cfg" || ! -f hooks/ycrc_hooks.py ]]; then
    echo "NOT-EBFILES: $here is not the root of a ycrc-ebfiles clone${CLUSTER:+ with siteconfigs/$CLUSTER.cfg}${CLUSTER:-, or \$CLUSTER is not set}."
    exit 11
fi
echo "OK: $user (support) at ycrc-ebfiles clone $here"
