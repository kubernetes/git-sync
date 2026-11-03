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
	"os"
	"testing"
	"time"
)

const (
	testKey = "KEY"
	alt1Key = "ALT1"
	alt2Key = "ALT2"
)

func setupEnv(val, alt1, alt2 string) {
	if val != "" {
		os.Setenv(testKey, val)
	}
	if alt1 != "" {
		os.Setenv(alt1Key, alt1)
	}
	if alt2 != "" {
		os.Setenv(alt2Key, alt2)
	}
}

func resetEnv() {
	os.Unsetenv(testKey)
	os.Unsetenv(alt1Key)
	os.Unsetenv(alt2Key)
}

func TestEnvBool(t *testing.T) {
	envWarnfOverride = func(format string, args ...any) {
		t.Logf(format, args...)
	}
	defer func() { envWarnfOverride = nil }()

	cases := []struct {
		value string
		alt1  string
		alt2  string
		def   bool
		exp   bool
		err   bool
	}{
		{"true", "", "", true, true, false},
		{"true", "", "", false, true, false},
		{"", "", "", true, true, false},
		{"", "", "", false, false, false},
		{"false", "", "", true, false, false},
		{"false", "", "", false, false, false},
		{"", "", "", true, true, false},
		{"", "", "", false, false, false},
		{"invalid", "", "", false, false, true},
		{"invalid", "true", "", false, true, false},
		{"true", "invalid", "", false, false, true},
		{"invalid", "invalid", "true", false, true, false},
		{"true", "true", "invalid", false, false, true},
		{"invalid", "invalid", "invalid", false, false, true},
	}

	for i, tc := range cases {
		resetEnv()
		setupEnv(tc.value, tc.alt1, tc.alt2)
		val, err := envBoolOrError(tc.def, testKey, alt1Key, alt2Key)
		if err != nil && !tc.err {
			t.Fatalf("%d: %q: unexpected error: %v", i, tc.value, err)
		}
		if err == nil && tc.err {
			t.Fatalf("%d: %q: unexpected success", i, tc.value)
		}
		if val != tc.exp {
			t.Fatalf("%d: expected: %v, got: %v", i, tc.exp, val)
		}
	}
}

func TestEnvString(t *testing.T) {
	envWarnfOverride = func(format string, args ...any) {
		t.Logf(format, args...)
	}
	defer func() { envWarnfOverride = nil }()

	cases := []struct {
		value string
		alt1  string
		alt2  string
		def   string
		exp   string
	}{
		{"foo", "", "", "foo", "foo"},
		{"foo", "", "", "bar", "foo"},
		{"", "", "", "foo", "foo"},
		{"", "", "", "bar", "bar"},
		{"bar", "", "", "foo", "bar"},
		{"bar", "", "", "bar", "bar"},
		{"", "", "", "foo", "foo"},
		{"", "", "", "bar", "bar"},
		{"foo1", "foo2", "", "bar", "foo2"},
		{"foo1", "foo2", "foo3", "bar", "foo3"},
	}

	for i, tc := range cases {
		resetEnv()
		setupEnv(tc.value, tc.alt1, tc.alt2)
		val := envString(tc.def, testKey, alt1Key, alt2Key)
		if val != tc.exp {
			t.Fatalf("%d: expected: %q, got: %q", i, tc.exp, val)
		}
	}
}

func TestEnvInt(t *testing.T) {
	envWarnfOverride = func(format string, args ...any) {
		t.Logf(format, args...)
	}
	defer func() { envWarnfOverride = nil }()

	cases := []struct {
		value string
		alt1  string
		alt2  string
		def   int
		exp   int
		err   bool
	}{
		{"0", "", "", 1, 0, false},
		{"", "", "", 0, 0, false},
		{"-1", "", "", 0, -1, false},
		{"invalid", "", "", 0, 0, true},
		{"invalid", "0", "", 1, 0, false},
		{"0", "invalid", "", 0, 0, true},
		{"invalid", "invalid", "0", 1, 0, false},
		{"0", "0", "invalid", 0, 0, true},
		{"invalid", "invalid", "invalid", 0, 0, true},
	}

	for i, tc := range cases {
		resetEnv()
		setupEnv(tc.value, tc.alt1, tc.alt2)
		val, err := envIntOrError(tc.def, testKey, alt1Key, alt2Key)
		if err != nil && !tc.err {
			t.Fatalf("%d: %q: unexpected error: %v", i, tc.value, err)
		}
		if err == nil && tc.err {
			t.Fatalf("%d: %q: unexpected success", i, tc.value)
		}
		if val != tc.exp {
			t.Fatalf("%d: expected: %v, got: %v", i, tc.exp, val)
		}
	}
}

func TestEnvFloat(t *testing.T) {
	envWarnfOverride = func(format string, args ...any) {
		t.Logf(format, args...)
	}
	defer func() { envWarnfOverride = nil }()

	cases := []struct {
		value string
		alt1  string
		alt2  string
		def   float64
		exp   float64
		err   bool
	}{
		{"0.5", "", "", 0, 0.5, false},
		{"", "", "", 0.5, 0.5, false},
		{"-0.5", "", "", 0, -0.5, false},
		{"invalid", "", "", 0, 0, true},
		{"invalid", "0.5", "", 0, 0.5, false},
		{"0.5", "invalid", "", 0, 0, true},
		{"invalid", "invalid", "0.5", 0, 0.5, false},
		{"0.5", "0.5", "invalid", 0, 0, true},
		{"invalid", "invalid", "invalid", 0, 0, true},
	}

	for i, tc := range cases {
		resetEnv()
		setupEnv(tc.value, tc.alt1, tc.alt2)
		val, err := envFloatOrError(tc.def, testKey, alt1Key, alt2Key)
		if err != nil && !tc.err {
			t.Fatalf("%d: %q: unexpected error: %v", i, tc.value, err)
		}
		if err == nil && tc.err {
			t.Fatalf("%d: %q: unexpected success", i, tc.value)
		}
		if val != tc.exp {
			t.Fatalf("%d: expected: %v, got: %v", i, tc.exp, val)
		}
	}
}

func TestEnvDuration(t *testing.T) {
	cases := []struct {
		value string
		alt1  string
		alt2  string
		def   time.Duration
		exp   time.Duration
		err   bool
	}{
		{"1s", "", "", 0, time.Second, false},
		{"", "", "", time.Minute, time.Minute, false},
		{"1h", "", "", 0, time.Hour, false},
		{"invalid", "", "", 0, 0, true},
		{"invalid", "1s", "", 0, time.Second, false},
		{"1s", "invalid", "", 0, 0, true},
		{"invalid", "invalid", "1s", 0, time.Second, false},
		{"1s", "1s", "invalid", 0, 0, true},
		{"invalid", "invalid", "invalid", 0, 0, true},
	}

	for i, tc := range cases {
		resetEnv()
		setupEnv(tc.value, tc.alt1, tc.alt2)
		val, err := envDurationOrError(tc.def, testKey, alt1Key, alt2Key)
		if err != nil && !tc.err {
			t.Fatalf("%d: %q: unexpected error: %v", i, tc.value, err)
		}
		if err == nil && tc.err {
			t.Fatalf("%d: %q: unexpected success", i, tc.value)
		}
		if val != tc.exp {
			t.Fatalf("%d: expected: %v, got: %v", i, tc.exp, val)
		}
	}
}
