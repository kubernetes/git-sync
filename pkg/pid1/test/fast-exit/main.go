/*
Copyright 2019 The Kubernetes Authors All rights reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

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
