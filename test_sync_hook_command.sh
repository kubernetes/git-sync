#!/bin/sh
# Use for e2e test of --sync-hook-command.
# This option takes no command arguments, so requires a wrapper script.

yes | cp -i file sync-hook
