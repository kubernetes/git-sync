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
	"cmp"
	"fmt"
	"io"
	"os"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/spf13/pflag"
)

// Tests can set this or set it to nil.
var envWarnfOverride func(format string, args ...any)

func envWarnf(format string, args ...any) {
	if envWarnfOverride != nil {
		envWarnfOverride(format, args...)
	} else {
		fmt.Fprintf(os.Stderr, format, args...)
	}
}

func envString(def string, key string, alts ...string) string {
	found := 0
	result := ""
	resultKey := ""

	if val, ok := os.LookupEnv(key); ok {
		found++
		result = val
		resultKey = key
	}
	for _, alt := range alts {
		if val, ok := os.LookupEnv(alt); ok {
			envWarnf("env $%s has been deprecated, use $%s instead\n", alt, key)
			found++
			result = val
			resultKey = alt
		}
	}
	if found == 0 {
		return def
	}
	if found > 1 {
		envWarnf("env $%s was overridden by $%s\n", key, resultKey)
	}
	return result
}
func envFlagString(key string, def string, usage string, alts ...string) *string {
	registerEnvFlag(key, "string", usage)
	val := envString(def, key, alts...)
	// also expose it as a flag, for easier testing
	flName := "__env__" + key
	flHelp := "DO NOT SET THIS FLAG EXCEPT IN TESTS; use $" + key
	newExplicitFlag(&val, flName, flHelp, pflag.String)
	if err := pflag.CommandLine.MarkHidden(flName); err != nil {
		fmt.Fprintf(os.Stderr, "FATAL: %v\n", err)
		os.Exit(1)
	}
	return &val
}

func envStringArray(def string, key string, alts ...string) []string {
	parse := func(s string) []string {
		return strings.Split(s, ":")
	}

	found := 0
	result := ""
	resultKey := ""

	if val, ok := os.LookupEnv(key); ok {
		found++
		result = val
		resultKey = key
	}
	for _, alt := range alts {
		if val, ok := os.LookupEnv(alt); ok {
			envWarnf("env $%s has been deprecated, use $%s instead\n", alt, key)
			found++
			result = val
			resultKey = key
		}
	}
	if found == 0 {
		return parse(def)
	}
	if found > 1 {
		envWarnf("env $%s was overridden by $%s\n", key, resultKey)
	}

	return parse(result)
}

func envBoolOrError(def bool, key string, alts ...string) (bool, error) {
	parse := func(key, val string) (bool, error) {
		parsed, err := strconv.ParseBool(val)
		if err == nil {
			return parsed, nil
		}
		return false, fmt.Errorf("invalid bool env %s=%q: %w", key, val, err)
	}

	found := 0
	result := ""
	resultKey := ""

	if val, ok := os.LookupEnv(key); ok {
		found++
		result = val
		resultKey = key
	}
	for _, alt := range alts {
		if val, ok := os.LookupEnv(alt); ok {
			envWarnf("env $%s has been deprecated, use $%s instead\n", alt, key)
			found++
			result = val
			resultKey = key
		}
	}
	if found == 0 {
		return def, nil
	}
	if found > 1 {
		envWarnf("env $%s was overridden by $%s\n", key, resultKey)
	}
	return parse(resultKey, result)
}
func envBool(def bool, key string, alts ...string) bool {
	val, err := envBoolOrError(def, key, alts...)
	if err != nil {
		fmt.Fprintf(os.Stderr, "FATAL: %v\n", err)
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
		return 0, fmt.Errorf("invalid int env %s=%q: %w", key, val, err)
	}

	found := 0
	result := ""
	resultKey := ""

	if val, ok := os.LookupEnv(key); ok {
		found++
		result = val
		resultKey = key
	}
	for _, alt := range alts {
		if val, ok := os.LookupEnv(alt); ok {
			envWarnf("env $%s has been deprecated, use $%s instead\n", alt, key)
			found++
			result = val
			resultKey = key
		}
	}
	if found == 0 {
		return def, nil
	}
	if found > 1 {
		envWarnf("env $%s was overridden by $%s\n", key, resultKey)
	}
	return parse(resultKey, result)
}
func envInt(def int, key string, alts ...string) int {
	val, err := envIntOrError(def, key, alts...)
	if err != nil {
		fmt.Fprintf(os.Stderr, "FATAL: %v\n", err)
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
		return 0, fmt.Errorf("invalid float env %s=%q: %w", key, val, err)
	}

	found := 0
	result := ""
	resultKey := ""

	if val, ok := os.LookupEnv(key); ok {
		found++
		result = val
		resultKey = key
	}
	for _, alt := range alts {
		if val, ok := os.LookupEnv(alt); ok {
			envWarnf("env $%s has been deprecated, use $%s instead\n", alt, key)
			found++
			result = val
			resultKey = key
		}
	}
	if found == 0 {
		return def, nil
	}
	if found > 1 {
		envWarnf("env $%s was overridden by $%s\n", key, resultKey)
	}
	return parse(resultKey, result)
}
func envFloat(def float64, key string, alts ...string) float64 {
	val, err := envFloatOrError(def, key, alts...)
	if err != nil {
		fmt.Fprintf(os.Stderr, "FATAL: %v\n", err)
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
		return 0, fmt.Errorf("invalid duration env %s=%q: %w", key, val, err)
	}

	found := 0
	result := ""
	resultKey := ""

	if val, ok := os.LookupEnv(key); ok {
		found++
		result = val
		resultKey = key
	}
	for _, alt := range alts {
		if val, ok := os.LookupEnv(alt); ok {
			envWarnf("env $%s has been deprecated, use $%s instead\n", alt, key)
			found++
			result = val
			resultKey = key
		}
	}
	if found == 0 {
		return def, nil
	}
	if found > 1 {
		envWarnf("env $%s was overridden by $%s\n", key, resultKey)
	}
	return parse(resultKey, result)
}
func envDuration(def time.Duration, key string, alts ...string) time.Duration {
	val, err := envDurationOrError(def, key, alts...)
	if err != nil {
		fmt.Fprintf(os.Stderr, "FATAL: %v\n", err)
		os.Exit(1)
		return 0
	}
	return val
}

// explicitFlag is a pflag.Value which only sets the real value if the flag is
// set to a non-zero-value.
type explicitFlag[T comparable] struct {
	pflag.Value
	realPtr *T
	flagPtr *T
}

// newExplicitFlag allocates an explicitFlag.
func newExplicitFlag[T comparable](ptr *T, name, usage string, fn func(name string, value T, usage string) *T) {
	h := &explicitFlag[T]{
		realPtr: ptr,
	}
	var zero T
	h.flagPtr = fn(name, zero, usage)
	fl := pflag.CommandLine.Lookup(name)
	// wrap the original pflag.Value with our own
	h.Value = fl.Value
	fl.Value = h
}

func (h *explicitFlag[T]) Set(val string) error {
	if err := h.Value.Set(val); err != nil {
		return err
	}
	var zero T
	if v := *h.flagPtr; v != zero {
		*h.realPtr = v
	}
	return nil
}

// envFlag is like a flag in that it is declared with a type, validated, and
// shows up in help messages, but can only be set by env-var, not on the CLI.
// This is useful for things like passwords, which should not be on the CLI
// because it can be seen in `ps`.
type envFlag struct {
	name string
	typ  string
	help string
}

var allEnvFlags = []envFlag{}

// registerEnvFlag is internal.  Use functions like envFlagString to actually
// create envFlags.
func registerEnvFlag(name, typ, help string) {
	for _, ef := range allEnvFlags {
		if ef.name == name {
			fmt.Fprintf(os.Stderr, "FATAL: duplicate env var declared: %q\n", name)
			os.Exit(1)
		}
	}
	allEnvFlags = append(allEnvFlags, envFlag{name, typ, help})
}

// printEnvFlags prints "usage" for all registered envFlags.
func printEnvFlags(out io.Writer) {
	width := 0
	for _, ef := range allEnvFlags {
		if n := len(ef.name); n > width {
			width = n
		}
	}
	slices.SortFunc(allEnvFlags, func(l, r envFlag) int { return cmp.Compare(l.name, r.name) })

	for _, ef := range allEnvFlags {
		fmt.Fprintf(out, "% *s %s %*s%s\n", width+2, ef.name, ef.typ, max(8, 32-width), "", ef.help)
	}
}
