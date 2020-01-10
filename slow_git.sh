#!/bin/sh

if [ "$1" != "clone" ]; then
  git "$@"
  exit $?
fi

sleep 1.1
git "$@"
