// Copyright 2019 Google Inc. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package main

import (
	"context"
	"encoding/csv"
	"os"

	"github.com/golang/glog"
	"github.com/google/go-licenses/licenses"
	"github.com/spf13/cobra"
)

var (
	csvHelp = "Prints all licenses that apply to one or more Go packages and their dependencies."
	csvCmd  = &cobra.Command{
		Use:   "csv <package> [package...]",
		Short: csvHelp,
		Long:  csvHelp + packageHelp,
		Args:  cobra.MinimumNArgs(1),
		RunE:  csvMain,
	}

	gitRemotes []string
)

func init() {
	csvCmd.Flags().StringArrayVar(&gitRemotes, "git_remote", []string{"origin", "upstream"}, "Remote Git repositories to try")

	rootCmd.AddCommand(csvCmd)
}

func csvMain(_ *cobra.Command, args []string) error {
	writer := csv.NewWriter(os.Stdout)

	classifier, err := licenses.NewClassifier(confidenceThreshold)
	if err != nil {
		return err
	}

	libs, err := licenses.Libraries(context.Background(), classifier, ignore, args...)
	if err != nil {
		return err
	}
	for _, lib := range libs {
		licenseURL := "Unknown"
		licenseName := "Unknown"
		if lib.LicensePath != "" {
			name, _, err := classifier.Identify(lib.LicensePath)
			if err == nil {
				licenseName = name
			} else {
				glog.Errorf("Error identifying license in %q: %v", lib.LicensePath, err)
			}
			url, err := lib.FileURL(context.Background(), lib.LicensePath)
			if err == nil {
				licenseURL = url
			} else {
				glog.Warningf("Error discovering license URL: %s", err)
			}
		}
		if err := writer.Write([]string{lib.Name(), licenseURL, licenseName}); err != nil {
			return err
		}
	}
	writer.Flush()
	return writer.Error()
}
