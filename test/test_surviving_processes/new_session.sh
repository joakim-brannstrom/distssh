#!/bin/bash

# FreeBSD
# stty -echo -onlcr   # avoid added \r in output
# script -q /dev/null /path/to/myscript
# stty echo onlcr
# sync  # ... if terminal prompt does not return

setsid make -j
