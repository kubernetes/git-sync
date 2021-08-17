/*
Copyright 2015 The Kubernetes Authors All rights reserved.

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

package main

import (
	"io/ioutil"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

const (
	testKey = "KEY"
)

func TestEnvBool(t *testing.T) {
	cases := []struct {
		value string
		def   bool
		exp   bool
	}{
		{"true", true, true},
		{"true", false, true},
		{"", true, true},
		{"", false, false},
		{"false", true, false},
		{"false", false, false},
		{"", true, true},
		{"", false, false},
		{"no true", true, true},
		{"no false", true, true},
	}

	for _, testCase := range cases {
		os.Setenv(testKey, testCase.value)
		val := envBool(testKey, testCase.def)
		if val != testCase.exp {
			t.Fatalf("expected %v but %v returned", testCase.exp, val)
		}
	}
}

func TestEnvString(t *testing.T) {
	cases := []struct {
		value string
		def   string
		exp   string
	}{
		{"true", "true", "true"},
		{"true", "false", "true"},
		{"", "true", "true"},
		{"", "false", "false"},
		{"false", "true", "false"},
		{"false", "false", "false"},
		{"", "true", "true"},
		{"", "false", "false"},
	}

	for _, testCase := range cases {
		os.Setenv(testKey, testCase.value)
		val := envString(testKey, testCase.def)
		if val != testCase.exp {
			t.Fatalf("expected %v but %v returned", testCase.exp, val)
		}
	}
}

func TestEnvInt(t *testing.T) {
	cases := []struct {
		value string
		def   int
		exp   int
	}{
		{"0", 1, 0},
		{"", 0, 0},
		{"-1", 0, -1},
		{"abcd", 0, 0},
		{"abcd", 1, 1},
	}

	for _, testCase := range cases {
		os.Setenv(testKey, testCase.value)
		val := envInt(testKey, testCase.def)
		if val != testCase.exp {
			t.Fatalf("expected %v but %v returned", testCase.exp, val)
		}
	}
}

func TestEnvFloat(t *testing.T) {
	cases := []struct {
		value string
		def   float64
		exp   float64
	}{
		{"0.5", 0, 0.5},
		{"", 0.5, 0.5},
		{"-0.5", 0, -0.5},
		{"abcd", 0.5, 0.5},
		{"abcd", 1.5, 1.5},
	}

	for _, testCase := range cases {
		os.Setenv(testKey, testCase.value)
		val := envFloat(testKey, testCase.def)
		if val != testCase.exp {
			t.Fatalf("expected %v but %v returned", testCase.exp, val)
		}
	}
}

func TestEnvDuration(t *testing.T) {
	cases := []struct {
		value string
		def   time.Duration
		exp   time.Duration
	}{
		{"1s", 0, time.Second},
		{"", time.Minute, time.Minute},
		{"1h", 0, time.Hour},
		{"abcd", time.Second, time.Second},
		{"abcd", time.Minute, time.Minute},
	}

	for _, testCase := range cases {
		os.Setenv(testKey, testCase.value)
		val := envDuration(testKey, testCase.def)
		if val != testCase.exp {
			t.Fatalf("expected %v but %v returned", testCase.exp, val)
		}
	}
}

func TestManualHasNoTabs(t *testing.T) {
	if strings.Contains(manual, "\t") {
		t.Fatal("the manual text contains a tab")
	}
}

func TestParseGitConfigs(t *testing.T) {
	cases := []struct {
		name   string
		input  string
		expect []keyVal
		fail   bool
	}{{
		name:   "empty",
		input:  ``,
		expect: []keyVal{},
	}, {
		name:   "one-pair",
		input:  `k:v`,
		expect: []keyVal{keyVal{"k", "v"}},
	}, {
		name:   "one-pair-qval",
		input:  `k:"v"`,
		expect: []keyVal{keyVal{"k", "v"}},
	}, {
		name:  "garbage",
		input: `abc123`,
		fail:  true,
	}, {
		name:  "invalid-val",
		input: `k:v\xv`,
		fail:  true,
	}, {
		name:  "invalid-qval",
		input: `k:"v\xv"`,
		fail:  true,
	}, {
		name:   "two-pair",
		input:  `k1:v1,k2:v2`,
		expect: []keyVal{{"k1", "v1"}, {"k2", "v2"}},
	}, {
		name:   "val-spaces",
		input:  `k1:v 1,k2:v 2`,
		expect: []keyVal{{"k1", "v 1"}, {"k2", "v 2"}},
	}, {
		name:   "qval-spaces",
		input:  `k1:" v 1 ",k2:" v 2 "`,
		expect: []keyVal{{"k1", " v 1 "}, {"k2", " v 2 "}},
	}, {
		name:   "mix-val-qval",
		input:  `k1:v 1,k2:" v 2 "`,
		expect: []keyVal{{"k1", "v 1"}, {"k2", " v 2 "}},
	}, {
		name:  "garbage-after-qval",
		input: `k1:"v1"x,k2:"v2"`,
		fail:  true,
	}, {
		name:   "dangling-comma",
		input:  `k1:"v1",k2:"v2",`,
		expect: []keyVal{{"k1", "v1"}, {"k2", "v2"}},
	}, {
		name:   "val-escapes",
		input:  `k1:v\n\t\\\"\,1`,
		expect: []keyVal{{"k1", "v\n\t\\\",1"}},
	}, {
		name:   "qval-escapes",
		input:  `k1:"v\n\t\\\"\,1"`,
		expect: []keyVal{{"k1", "v\n\t\\\",1"}},
	}, {
		name:   "qval-comma",
		input:  `k1:"v,1"`,
		expect: []keyVal{{"k1", "v,1"}},
	}, {
		name:  "qval-missing-close",
		input: `k1:"v1`,
		fail:  true,
	}}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			kvs, err := parseGitConfigs(tc.input)
			if err != nil && !tc.fail {
				t.Errorf("unexpected error: %v", err)
			}
			if err == nil && tc.fail {
				t.Errorf("unexpected success")
			}
			if !reflect.DeepEqual(kvs, tc.expect) {
				t.Errorf("bad result: expected %v, got %v", tc.expect, kvs)
			}
		})
	}
}

func TestDirIsEmpty(t *testing.T) {
	root, err := ioutil.TempDir("", "")
	if err != nil {
		t.Fatalf("failed to make a temp dir: %v", err)
	}

	// Brand new should be empty.
	if empty, err := dirIsEmpty(root); err != nil {
		t.Fatalf("unexpected error: %v", err)
	} else if !empty {
		t.Errorf("expected %q to be deemed empty", root)
	}

	// Holding normal files should not be empty.
	dir := filepath.Join(root, "files")
	if err := os.Mkdir(dir, 0755); err != nil {
		t.Fatalf("failed to make a temp subdir: %v", err)
	}
	for _, file := range []string{"a", "b", "c"} {
		path := filepath.Join(dir, file)
		if err := ioutil.WriteFile(path, []byte{}, 0755); err != nil {
			t.Fatalf("failed to write a file: %v", err)
		}
		if empty, err := dirIsEmpty(dir); err != nil {
			t.Fatalf("unexpected error: %v", err)
		} else if empty {
			t.Errorf("expected %q to be deemed not-empty", dir)
		}
	}

	// Holding dot-files should not be empty.
	dir = filepath.Join(root, "dot-files")
	if err := os.Mkdir(dir, 0755); err != nil {
		t.Fatalf("failed to make a temp subdir: %v", err)
	}
	for _, file := range []string{".a", ".b", ".c"} {
		path := filepath.Join(dir, file)
		if err := ioutil.WriteFile(path, []byte{}, 0755); err != nil {
			t.Fatalf("failed to write a file: %v", err)
		}
		if empty, err := dirIsEmpty(dir); err != nil {
			t.Fatalf("unexpected error: %v", err)
		} else if empty {
			t.Errorf("expected %q to be deemed not-empty", dir)
		}
	}

	// Holding dirs should not be empty.
	dir = filepath.Join(root, "dirs")
	if err := os.Mkdir(dir, 0755); err != nil {
		t.Fatalf("failed to make a temp subdir: %v", err)
	}
	for _, subdir := range []string{"a", "b", "c"} {
		path := filepath.Join(dir, subdir)
		if err := os.Mkdir(path, 0755); err != nil {
			t.Fatalf("failed to make a subdir: %v", err)
		}
		if empty, err := dirIsEmpty(dir); err != nil {
			t.Fatalf("unexpected error: %v", err)
		} else if empty {
			t.Errorf("expected %q to be deemed not-empty", dir)
		}
	}

	// Test error path.
	if _, err := dirIsEmpty(filepath.Join(root, "does-not-exist")); err == nil {
		t.Errorf("unexpected success for non-existent dir")
	}
}

func TestRemoveDirContents(t *testing.T) {
	root, err := ioutil.TempDir("", "")
	if err != nil {
		t.Fatalf("failed to make a temp dir: %v", err)
	}

	// Brand new should be empty.
	if empty, err := dirIsEmpty(root); err != nil {
		t.Fatalf("unexpected error: %v", err)
	} else if !empty {
		t.Errorf("expected %q to be deemed empty", root)
	}

	// Test removal.
	if err := removeDirContents(root, nil); err != nil {
		t.Errorf("unexpected error: %v", err)
	}

	// Populate the dir.
	for _, file := range []string{"f1", "f2", ".f3", ".f4"} {
		path := filepath.Join(root, file)
		if err := ioutil.WriteFile(path, []byte{}, 0755); err != nil {
			t.Fatalf("failed to write a file: %v", err)
		}
	}
	for _, subdir := range []string{"d1", "d2", "d3"} {
		path := filepath.Join(root, subdir)
		if err := os.Mkdir(path, 0755); err != nil {
			t.Fatalf("failed to make a subdir: %v", err)
		}
	}

	// It should be deemed not-empty
	if empty, err := dirIsEmpty(root); err != nil {
		t.Fatalf("unexpected error: %v", err)
	} else if empty {
		t.Errorf("expected %q to be deemed not-empty", root)
	}

	// Test removal.
	if err := removeDirContents(root, nil); err != nil {
		t.Errorf("unexpected error: %v", err)
	}

	// Test error path.
	if err := removeDirContents(filepath.Join(root, "does-not-exist"), nil); err == nil {
		t.Errorf("unexpected success for non-existent dir")
	}
}
