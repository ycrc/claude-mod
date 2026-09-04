
salloc -p devel --mem=20G -t 0-4

#==== Build

cd ~/project/claude-mod

mkdir ~/scratch/claude-mod

outD=~/scratch/claude-mod

apptainer build --fakeroot --force $outD/claude-mod.sif claude-mod.def 2>&1 | tee $outD/build.log


