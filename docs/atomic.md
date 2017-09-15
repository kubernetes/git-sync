# Atomic updates
By design git-sync uses symlinks to atomically switch git content between versions.
Various applications might not work well with symlinks in general.
Symlink changes might not be recognized as an update to the content. (inotify might be configured to follow symlinks instead of watching for a symlink update)

To disable the atomic switch via symlinks set ```GIT_SYNC_ATOMIC``` to false.
