---
description: Test to validate the .julia folder is bound and usable
expectation: Should find the Example package in the ~/.julia folder
notes: Had to tell Sonnet to load the module otherwise it would fail.
---
Load Julia using 'ml Julia'. Using Julia, determine the path to the Example package. Run a julia command to retrieve the path rather than guessing or seaching the filesystem. 
If the example package is not available, install it.
