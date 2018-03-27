#!/bin/bash

set -e

pushd test
dub test
popd
