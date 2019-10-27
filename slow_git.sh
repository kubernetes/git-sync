#!/bin/sh

if [ "$1" != "fetch" ]; then
  git "$@"
  exit $?
fi

sleep 1.1
git "$@"
