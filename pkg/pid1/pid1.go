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
// this will return the same value as exec.Command.Run(). If there is an error
// in reaping children that this can not handle, it will panic.
func ReRun() error {
	bin, err := os.Readlink("/proc/self/exe")
	if err != nil {
		return err
	}
	cmd := exec.Command(bin, os.Args[1:]...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		return err
	}
	go runInit(cmd.Process.Pid)
	return cmd.Wait()
}

// runInit runs a bare-bones init process.  This will never return.  In case of
// truly unknown errors it will panic.
func runInit(pid int) {
	sigs := make(chan os.Signal, 8)
	signal.Notify(sigs)
	for sig := range sigs {
		if sig == syscall.SIGCHLD {
			sigchld()
		} else {
			// Pass it on to the real process.
			syscall.Kill(pid, sig.(syscall.Signal))
		}
	}
}

// sigchld handles a SIGCHLD.
func sigchld() {
	// Loop to handle multiple child processes.
	for {
		var status syscall.WaitStatus
		pid, err := syscall.Wait4(-1, &status, syscall.WNOHANG, nil)
		if err != nil {
			panic(fmt.Sprintf("failed to wait4(): %v\n", err))
		}
		if pid <= 0 {
			// No more children to reap.
			break
		}
		// Must have found one, see if there are more.
	}
}
