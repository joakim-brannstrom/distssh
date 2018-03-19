#!/bin/bash

echo $DISTSSH_TEST_ENV

if [[ "$DISTSSH_TEST_ENV" = "4242" ]]; then
    exit 0
else
    exit 1
fi
