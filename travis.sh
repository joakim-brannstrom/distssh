#!/bin/bash

export DISTSSH_HOSTS=localhost

set -e

dub test -- -s

pushd test
dub test -- -s
popd
