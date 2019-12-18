#!/bin/sh
# Ask pass when cloning new repo, fail if it mismatched the magic password.

mkdir -p "${XDG_CONFIG_HOME}/git/"
# Override the default 'git --global' config location, the default location
# outside the e2e test environment. See https://git-scm.com/docs/git-config
touch "${XDG_CONFIG_HOME}/git/config"
# Override the default 'git credential store' config location, the default location
# outside the e2e test environment. See https://git-scm.com/docs/git-credential-store
touch "${XDG_CONFIG_HOME}/git/credentials"

if [ "$1" != "clone" ]; then
  git "$@"
  exit $?
fi

REPO=$(echo "$@" | grep -o "file://[^ ]*")
PASSWD=$(echo "url=${REPO}" | git credential fill | grep -o "password=.*")
# Test case much match the magic password below.
if [ "${PASSWD}" != "password=Lov3!k0os" ]; then
  echo "invalid password ${PASSWD}, try Lov3!k0os next time."
  exit 1
fi

git "$@"
