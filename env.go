/*
Copyright 2014 The Kubernetes Authors All rights reserved.

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
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

func envString(def string, key string, alts ...string) string {
	if val := os.Getenv(key); val != "" {
		return val
	}
	for _, alt := range alts {
		if val := os.Getenv(alt); val != "" {
			fmt.Fprintf(os.Stderr, "env %s has been deprecated, use %s instead\n", alt, key)
			return val
		}
	}
	return def
}

func envStringArray(def string, key string, alts ...string) []string {
	parse := func(s string) []string {
		return strings.Split(s, ":")
	}

	if val := os.Getenv(key); val != "" {
		return parse(val)
	}
	for _, alt := range alts {
		if val := os.Getenv(alt); val != "" {
			fmt.Fprintf(os.Stderr, "env %s has been deprecated, use %s instead\n", alt, key)
			return parse(val)
		}
	}
	return parse(def)
}

func envBoolOrError(def bool, key string, alts ...string) (bool, error) {
	parse := func(key, val string) (bool, error) {
		parsed, err := strconv.ParseBool(val)
		if err == nil {
			return parsed, nil
		}
		return false, fmt.Errorf("ERROR: invalid bool env %s=%q: %w", key, val, err)
	}

	if val := os.Getenv(key); val != "" {
		return parse(key, val)
	}
	for _, alt := range alts {
		if val := os.Getenv(alt); val != "" {
			fmt.Fprintf(os.Stderr, "env %s has been deprecated, use %s instead\n", alt, key)
			return parse(alt, val)
		}
	}
	return def, nil
}
func envBool(def bool, key string, alts ...string) bool {
	val, err := envBoolOrError(def, key, alts...)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
		return false
	}
	return val
}

func envIntOrError(def int, key string, alts ...string) (int, error) {
	parse := func(key, val string) (int, error) {
		parsed, err := strconv.ParseInt(val, 0, 0)
		if err == nil {
			return int(parsed), nil
		}
		return 0, fmt.Errorf("ERROR: invalid int env %s=%q: %w", key, val, err)
	}

	if val := os.Getenv(key); val != "" {
		return parse(key, val)
	}
	for _, alt := range alts {
		if val := os.Getenv(alt); val != "" {
			fmt.Fprintf(os.Stderr, "env %s has been deprecated, use %s instead\n", alt, key)
			return parse(alt, val)
		}
	}
	return def, nil
}
func envInt(def int, key string, alts ...string) int {
	val, err := envIntOrError(def, key, alts...)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
		return 0
	}
	return val
}

func envFloatOrError(def float64, key string, alts ...string) (float64, error) {
	parse := func(key, val string) (float64, error) {
		parsed, err := strconv.ParseFloat(val, 64)
		if err == nil {
			return parsed, nil
		}
		return 0, fmt.Errorf("ERROR: invalid float env %s=%q: %w", key, val, err)
	}

	if val := os.Getenv(key); val != "" {
		return parse(key, val)
	}
	for _, alt := range alts {
		if val := os.Getenv(alt); val != "" {
			fmt.Fprintf(os.Stderr, "env %s has been deprecated, use %s instead\n", alt, key)
			return parse(alt, val)
		}
	}
	return def, nil
}
func envFloat(def float64, key string, alts ...string) float64 {
	val, err := envFloatOrError(def, key, alts...)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
		return 0
	}
	return val
}

func envDurationOrError(def time.Duration, key string, alts ...string) (time.Duration, error) {
	parse := func(key, val string) (time.Duration, error) {
		parsed, err := time.ParseDuration(val)
		if err == nil {
			return parsed, nil
		}
		return 0, fmt.Errorf("ERROR: invalid duration env %s=%q: %w", key, val, err)
	}

	if val := os.Getenv(key); val != "" {
		return parse(key, val)
	}
	for _, alt := range alts {
		if val := os.Getenv(alt); val != "" {
			fmt.Fprintf(os.Stderr, "env %s has been deprecated, use %s instead\n", alt, key)
			return parse(alt, val)
		}
	}
	return def, nil
}
func envDuration(def time.Duration, key string, alts ...string) time.Duration {
	val, err := envDurationOrError(def, key, alts...)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
		return 0
	}
	return val
}
