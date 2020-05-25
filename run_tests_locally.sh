#!/bin/bash

export DISTSSH_HOSTS=localhost

set -ex

dub test
dub build

pushd test
rm -rf build/testdata
dub test -- -s -d
popd

find . -iname "*.sqlite3" -delete
