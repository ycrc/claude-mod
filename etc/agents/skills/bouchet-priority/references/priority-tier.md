# YCRC Priority Tier reference for Bouchet agents

Key YCRC documentation points:

- Priority Tier is an opt-in paid fast lane; Standard Tier, private nodes, and scavenge remain free of Priority Tier charges.
- Access is granted through Priority Tier onboarding, with approved users able to incur charges.
- Bouchet provides `priority`, `priority_gpu`, and `priority_mpi` partitions.
- Interactive jobs are permitted on Priority Tier partitions.
- Priority Tier does not guarantee immediate start; jobs precede Standard Tier jobs but still wait for resources and other Priority Tier jobs.
- Priority Tier submissions require a `prio_...` Slurm account specified with `-A`.
- `prio_...` accounts cannot be used in Standard Tier partitions.
- Priority GPU costs differ by GPU model; YCRC recommends being specific about GPU model to avoid unexpected costs.
- Billing is based on actual runtime, and all allocated resources are billed regardless of utilization.
- Groups can set annual usage limits and can inspect usage with `getusage -g prio_groupname` and the YCRC User Portal.

Operational agent rule added by this deployment: before the agent itself performs a submission, interactive allocation, resubmission, or partition change that will use Priority Tier, it must explicitly tell the user that paid Priority Tier credits will be consumed and obtain confirmation for that job or clearly defined batch.
