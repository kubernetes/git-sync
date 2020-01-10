package main

import (
	"io/ioutil"
	"os"
	"strconv"
	"strings"
	"syscall"
)

var signalMap = map[string]int{
	"SIGHUP":    1,
	"SIGINT":    2,
	"SIGQUIT":   3,
	"SIGILL":    4,
	"SIGTRAP":   5,
	"SIGABRT":   6,
	"SIGBUS":    7,
	"SIGFPE":    8,
	"SIGKILL":   9,
	"SIGUSR1":   10,
	"SIGSEGV":   11,
	"SIGUSR2":   12,
	"SIGPIPE":   13,
	"SIGALRM":   14,
	"SIGTERM":   15,
	"SIGSTKFLT": 16,
	"SIGCHLD":   17,
	"SIGCONT":   18,
	"SIGSTOP":   19,
	"SIGTSTP":   20,
	"SIGTTIN":   21,
	"SIGTTOU":   22,
	"SIGURG":    23,
	"SIGXCPU":   24,
	"SIGXFSZ":   25,
	"SIGVTALRM": 26,
	"SIGPROF":   27,
	"SIGWINCH":  28,
	"SIGIO":     29,
	"SIGPWR":    30,
	"SIGSYS":    31,
}

func ConvertSignal(flProcSignal string) (syscall.Signal, error) {
	sig, err := strconv.ParseInt(flProcSignal, 10, 32)
	if err == nil {
		return syscall.Signal(sig), nil
	} else {
		if sig, ok := signalMap[flProcSignal]; ok {
			return syscall.Signal(sig), nil
		}
	}
	return syscall.Signal(1), nil
}

func SignalProcs(flProcName string, sig syscall.Signal) error {
	pids, err := getPids()
	if err != nil {
		return err
	}
	for _, pid := range pids {
		if getName(pid) == flProcName {
			err := syscall.Kill(int(pid), sig)
			if err != nil {
				return err
			}
		}
	}
	return nil
}

func getHostProc() string {
	procDir, found := os.LookupEnv("HOST_PROC")
	if !found {
		procDir = "/proc"
	}
	return procDir
}

func getPids() ([]int32, error) {
	var ret []int32
	files, err := ioutil.ReadDir(getHostProc())
	if err != nil {
		return nil, err
	}
	for _, file := range files {
		if file.IsDir() {
			pid, err := strconv.ParseInt(file.Name(), 10, 32)
			if err == nil {
				ret = append(ret, int32(pid))
			}
		}
	}
	return ret, nil
}

func getName(pid int32) string {
	statusFile := getHostProc() + "/" + strconv.Itoa(int(pid)) + "/status"
	fileBytes, err := ioutil.ReadFile(statusFile)
	if err != nil {
		return ""
	}
	lines := strings.Split(string(fileBytes), "\n")
	parts := strings.Split(lines[0], ":")
	if parts[0] == "Name" {
		return strings.Trim(parts[1], "\t ")
	}
	return ""
}
