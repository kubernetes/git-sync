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
)

func TestEnvBool(t *testing.T) {
	cases := []struct {
		value string
		def   bool
		exp   bool
		err   bool
	}{
		{"true", true, true, false},
		{"true", false, true, false},
		{"", true, true, false},
		{"", false, false, false},
		{"false", true, false, false},
		{"false", false, false, false},
		{"", true, true, false},
		{"", false, false, false},
		{"no true", false, false, true},
		{"no false", false, false, true},
	}

	for _, testCase := range cases {
		os.Setenv(testKey, testCase.value)
		val, err := envBoolOrError(testCase.def, testKey)
		if err != nil && !testCase.err {
			t.Fatalf("%q: unexpected error: %v", testCase.value, err)
		}
		if err == nil && testCase.err {
			t.Fatalf("%q: unexpected success", testCase.value)
		}
		if val != testCase.exp {
			t.Fatalf("%q: expected %v but %v returned", testCase.value, testCase.exp, val)
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
		val := envString(testCase.def, testKey)
		if val != testCase.exp {
			t.Fatalf("%q: expected %v but %v returned", testCase.value, testCase.exp, val)
		}
	}
}

func TestEnvInt(t *testing.T) {
	cases := []struct {
		value string
		def   int
		exp   int
		err   bool
	}{
		{"0", 1, 0, false},
		{"", 0, 0, false},
		{"-1", 0, -1, false},
		{"abcd", 0, 0, true},
		{"abcd", 0, 0, true},
	}

	for _, testCase := range cases {
		os.Setenv(testKey, testCase.value)
		val, err := envIntOrError(testCase.def, testKey)
		if err != nil && !testCase.err {
			t.Fatalf("%q: unexpected error: %v", testCase.value, err)
		}
		if err == nil && testCase.err {
			t.Fatalf("%q: unexpected success", testCase.value)
		}
		if val != testCase.exp {
			t.Fatalf("%q: expected %v but %v returned", testCase.value, testCase.exp, val)
		}
	}
}

func TestEnvFloat(t *testing.T) {
	cases := []struct {
		value string
		def   float64
		exp   float64
		err   bool
	}{
		{"0.5", 0, 0.5, false},
		{"", 0.5, 0.5, false},
		{"-0.5", 0, -0.5, false},
		{"abcd", 0, 0, true},
	}

	for _, testCase := range cases {
		os.Setenv(testKey, testCase.value)
		val, err := envFloatOrError(testCase.def, testKey)
		if err != nil && !testCase.err {
			t.Fatalf("%q: unexpected error: %v", testCase.value, err)
		}
		if err == nil && testCase.err {
			t.Fatalf("%q: unexpected success", testCase.value)
		}
		if val != testCase.exp {
			t.Fatalf("%q: expected %v but %v returned", testCase.value, testCase.exp, val)
		}
	}
}

func TestEnvDuration(t *testing.T) {
	cases := []struct {
		value string
		def   time.Duration
		exp   time.Duration
		err   bool
	}{
		{"1s", 0, time.Second, false},
		{"", time.Minute, time.Minute, false},
		{"1h", 0, time.Hour, false},
		{"abcd", 0, 0, true},
	}

	for _, testCase := range cases {
		os.Setenv(testKey, testCase.value)
		val, err := envDurationOrError(testCase.def, testKey)
		if err != nil && !testCase.err {
			t.Fatalf("%q: unexpected error: %v", testCase.value, err)
		}
		if err == nil && testCase.err {
			t.Fatalf("%q: unexpected success", testCase.value)
		}
		if val != testCase.exp {
			t.Fatalf("%q: expected %v but %v returned", testCase.value, testCase.exp, val)
		}
	}
}
