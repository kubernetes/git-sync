// A do-nothing app to test pid1.ReRun().
package main

import (
	"fmt"
	"os"

	"k8s.io/git-sync/pkg/pid1"
)

func main() {
	// In case we come up as pid 1, act as init.
	if os.Getpid() == 1 {
		fmt.Printf("detected pid 1, running as init\n")
		code, err := pid1.ReRun()
		if err == nil {
			os.Exit(code)
		}
		fmt.Printf("unhandled pid1 error: %v\n", err)
		os.Exit(127)
	}
	fmt.Printf("main app\n")
	os.Exit(42)
}
