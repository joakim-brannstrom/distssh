#!/bin/bash

set -e

dub test

pushd test
dub test
popd
