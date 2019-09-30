#!/bin/bash

export DISTSSH_HOSTS=localhost

set -ex

dub test -- -s

pushd test
dub test -- -s
popd
