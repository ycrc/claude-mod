# GPU utilization, Jobstats, and resource policy

Sources:
- `docs/ai/gpu-jobstats.md`
- `docs/clusters-at-yale/policies.md`
- `docs/clusters/bouchet-rob.md`

YCRC monitors resource utilization, and users can inspect job usage with `jobstats JOBID`.

The YCRC GPU Jobstats documentation states that, as of 2026, Jobstats terminates jobs that are not using GPUs effectively, defined there as less than 10% usage, to keep limited GPU resources available for effective workloads.

Bouchet's Rules of Behavior require users to release idle resources and prohibit deliberately designing jobs to circumvent resource/fair-use policies. They state that accounts found circumventing resource policies may be locked immediately without advance notice.

For low GPU utilization, diagnose the real cause or change the resource request. Do not create artificial utilization or otherwise attempt to evade monitoring.
