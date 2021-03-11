package pid1

import (
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"syscall"
)

// ReRun converts the current process into a bare-bones init, runs the current
// commandline as a child process, and waits for it to complete.  The new child
// process shares stdin/stdout/stderr with the parent.  When the child exits,
// this will return the exit code. If this returns an error, the child process
// may not be terminated.
func ReRun() (int, error) {
	bin, err := os.Readlink("/proc/self/exe")
	if err != nil {
		return 0, err
	}
	cmd := exec.Command(bin, os.Args[1:]...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		return 0, err
	}
	return runInit(cmd.Process.Pid)
}

// runInit runs a bare-bones init process.  When firstborn exits, this will
// return the exit code.  If this returns an error, the child process may not
// be terminated.
func runInit(firstborn int) (int, error) {
	sigs := make(chan os.Signal, 8)
	signal.Notify(sigs)
	for sig := range sigs {
		if sig != syscall.SIGCHLD {
			// Pass it on to the real process.
			if err := syscall.Kill(firstborn, sig.(syscall.Signal)); err != nil {
				return 0, err
			}
		}
		// Always try to reap a child - empirically, sometimes this gets missed.
		die, status, err := sigchld(firstborn)
		if err != nil {
			return 0, err
		}
		if die {
			if status.Signaled() {
				return 128 + int(status.Signal()), nil
			}
			if status.Exited() {
				return status.ExitStatus(), nil
			}
			return 0, fmt.Errorf("unhandled exit status: 0x%x\n", status)
		}
	}
	return 0, fmt.Errorf("signal handler terminated unexpectedly")
}

// sigchld handles a SIGCHLD.  This will return true only when firstborn exits.
// For any other process this will return false and a 0 status.
func sigchld(firstborn int) (bool, syscall.WaitStatus, error) {
	// Loop to handle multiple child processes.
	for {
		var status syscall.WaitStatus
		pid, err := syscall.Wait4(-1, &status, syscall.WNOHANG, nil)
		if err != nil {
			return false, 0, fmt.Errorf("wait4(): %v\n", err)
		}

		if pid == firstborn {
			return true, status, nil
		}
		if pid <= 0 {
			// No more children to reap.
			break
		}
		// Must have found one, see if there are more.
	}
	return false, 0, nil
}
