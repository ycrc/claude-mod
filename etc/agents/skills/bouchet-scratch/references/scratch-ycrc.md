# YCRC source notes: Bouchet scratch

Derived primarily from the supplied YCRC documentation source:
`docs/data/hpc-storage.md`, section `Scratch`.

The current central storage documentation states:

- scratch is intended for temporary data;
- on Bouchet, files in scratch older than **30 days** are automatically deleted;
- YCRC sends weekly warnings about files expected to be deleted the following week;
- scratch quota is shared by the research group;
- users may be asked to delete files younger than the time limit if storage runs low;
- artificial extension of scratch file expiration is forbidden without explicit YCRC approval;
- users needing longer-term storage should use/purchase appropriate persistent storage.

The general account policy in
`docs/clusters-at-yale/access/accounts.md` independently states that use of
scratch for long-term storage through artificial extension of file expiration
or other means is forbidden without explicit YCRC approval.

Documentation consistency note:
`docs/clusters/bouchet-rob.md` still contains a 60-day statement, while the
current central `docs/data/hpc-storage.md` explicitly specifies **30 days for
Bouchet** and 60 days for McCleary/Grace/Milgram. This managed Bouchet skill
therefore uses the central storage page's Bouchet-specific 30-day value.
