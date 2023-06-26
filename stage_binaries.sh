#!/bin/bash

# Copyright 2022 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# USAGE: stage-binaries.sh -o <staging-dir> ( -p <package> | -b binary )..."
#
# Stages all the packages or files and their dependencies (+ libraries and
# copyrights) to the staging dir.
#
# This is intended to be used in a multi-stage docker build with a distroless/base
# or distroless/cc image.

set -o errexit
set -o nounset
set -o pipefail

# A handler for when we exit automatically on an error.
# Borrowed from kubernetes, which was borrowed from
# https://gist.github.com/ahendrix/7030300
function errexit() {
  # If the shell we are in doesn't have errexit set (common in subshells) then
  # don't dump stacks.
  set +o | grep -qe "-o errexit" || return

  local file="$(basename "${BASH_SOURCE[1]}")"
  local line="${BASH_LINENO[0]}"
  local func="${FUNCNAME[1]:-}"
  echo "FATAL: error at ${func}() ${file}:${line}" >&2
}

# trap ERR to provide an error handler whenever a command exits nonzero  this
# is a more verbose version of set -o errexit
trap 'errexit' ERR

# setting errtrace allows our ERR trap handler to be propagated to functions,
# expansions and subshells
set -o errtrace

# file_to_package identifies the debian package that provided the file $1
function file_to_package() {
    local file="$1"

    # `dpkg-query --search $file-pattern` outputs lines with the format: "$package: $file-path"
    # where $file-path belongs to $package
    # https://manpages.debian.org/jessie/dpkg/dpkg-query.1.en.html
    dpkg-query --search "$(realpath "${file}")" | cut -d':' -f1
}

# package_to_copyright gives the path to the copyright file for the package $1
function package_to_copyright() {
    local pkg="$1"
    echo "/usr/share/doc/${pkg}/copyright"
}

# stage_file stages the filepath $1 to $2, following symlinks
# and staging copyrights
function stage_file() {
    local file="$1"
    local staging="$2"

    # short circuit if we have done this file before
    if [[ -e "${staging}/${file}" ]]; then
        return
    fi

    # copy the named path
    cp -a --parents "${file}" "${staging}"

    # recursively follow symlinks
    if [[ -L "${file}" ]]; then
        stage_file "$(cd "$(dirname "${file}")" || exit; realpath -s "$(readlink "${file}")")" "${staging}"
    fi

    # get the package so we can stage package metadata as well
    local package="$(file_to_package "${file}")"
    # stage the copyright for the file, if it exists
    local copyright="$(package_to_copyright "${package}")"
    if [[ -f "${copyright}" ]]; then
        cp -a --parents "${copyright}" "${staging}"
    fi

    # stage the package status mimicking bazel
    # https://github.com/bazelbuild/rules_docker/commit/f5432b813e0a11491cf2bf83ff1a923706b36420
    # instead of parsing the control file, we can just get the actual package status with dpkg
    dpkg -s "${package}" > "${staging}/var/lib/dpkg/status.d/${package}"
}

function grep_allow_nomatch() {
    # grep exits 0 on match, 1 on no match, 2 on error
    grep "$@" || [[ $? == 1 ]]
}

function _indent() {
    while read -r X; do
        echo "    ${X}"
    done
}

# run "$@" and indent the output
function indent() {
    # This lets us process stderr and stdout without merging them, without
    # bash-isms.
    { "$@" 2>&1 1>&3 | _indent; } 3>&1 1>&2 | _indent
}

function stage_file_list() {
    local pkg="$1"
    local staging="$2"

    dpkg -L "${pkg}" \
        | grep_allow_nomatch -vE '(/\.|/usr/share/(man|doc|.*-completion))' \
        | while read -r file; do
            if [[ -f "$file" ]]; then
                stage_file "${file}" "${staging}"
                if [[ -L "$file" ]]; then
                    continue
                fi
                if [[ -x "$file" ]]; then
                    stage_binaries "${staging}" "${file}"
                fi
            fi
        done
}

function get_dependent_packages() {
    local pkg="$1"
    apt-cache depends "${pkg}" \
        | grep_allow_nomatch Depends \
        | awk -F '.*Depends:[[:space:]]?' '{print $2}'
}

# Args:
#   $1: path to staging dir
#   $2+: package names
function stage_packages() {
    local staging="$1"
    shift

    mkdir -p "${staging}"/var/lib/dpkg/status.d/
    indent apt-get -y -qq -o Dpkg::Use-Pty=0 update

    local pkg
    for pkg; do
        echo "staging package ${pkg}"
        indent apt-get -y -qq -o Dpkg::Use-Pty=0 --no-install-recommends install "${pkg}"
        stage_file_list "${pkg}" "$staging"
        get_dependent_packages "${pkg}" \
            | while read -r dep; do
                stage_file_list "${dep}" "${staging}"
            done
    done
}

# binary_to_libraries identifies the library files needed by the binary $1 with ldd
function binary_to_libraries() {
    local bin="$1"

    # see: https://man7.org/linux/man-pages/man1/ldd.1.html
    # Each output line looks like:
    #     linux-vdso.so.1 (0x00007fffb11c3000)
    #   or
    #     libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f2f52d26000)
    #
    # This is a little funky because ldd treats static binaries as errors ("not
    # a dynamic executable") but static libraries as non-errors ("statically
    # linked").  We want real ldd errors, but static binaries are OK.
    if [[ "$(ldd "${bin}" 2>&1)" =~ "not a dynamic executable" ]]; then
        return
    fi
    ldd "${bin}" \
        `# skip static binaries` \
        | grep_allow_nomatch -v "statically linked" \
        `# linux-vdso.so.1 is a special virtual shared object from the kernel` \
        `# see: http://man7.org/linux/man-pages/man7/vdso.7.html` \
        | grep_allow_nomatch -v 'linux-vdso.so.1' \
        `# strip the leading '${name} => ' if any so only '/lib-foo.so (0xf00)' remains` \
        | sed -E 's#.* => /#/#' \
        `# we want only the path remaining, not the (0x${LOCATION})` \
        | awk '{print $1}'
}

function stage_binaries() {
    local staging="$1"
    shift

    local bin
    for bin; do
        echo "staging binary ${bin}"

        # locate the path to the binary
        local binary_path
        binary_path="$(which "${bin}")"

        # ensure package metadata dir
        mkdir -p "${staging}/var/lib/dpkg/status.d/"

        # stage the binary itself
        stage_file "${binary_path}" "${staging}"

        # stage the dependencies of the binary
        binary_to_libraries "${binary_path}" \
            | while read -r lib; do
                stage_file "${lib}" "${staging}"
            done
    done
}

function usage() {
    echo "$0 -o <staging-dir> ( -p <package> | -b binary )..."
}

function main() {
    local staging=""
    local pkgs=()
    local bins=()

    while [ "$#" -gt 0 ]; do
    case "$1" in
        "-?")
            usage
            exit 0
            ;;
        "-b")
            if [[ -z "${2:-}" ]]; then
                echo "error: flag '-b' requires an argument" >&2
                usage >&2
                exit 2
            fi
            bins+=("$2")
            shift 2
            ;;
        "-p")
            if [[ -z "${2:-}" ]]; then
                echo "error: flag '-p' requires an argument" >&2
                usage >&2
                exit 2
            fi
            pkgs+=("$2")
            shift 2
            ;;
        "-o")
            if [[ -z "${2:-}" ]]; then
                echo "error: flag '-o' requires an argument" >&2
                usage >&2
                exit 2
            fi
            staging="$2"
            shift 2
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            usage >&2
            exit 3
            ;;
    esac
    done

    if [[ -z "${staging}" ]]; then
        usage >&2
        exit 4
    fi

    if (( "${#pkgs[@]}" > 0 )); then
        stage_packages "${staging}" "${pkgs[@]}"
    fi
    if (( "${#bins[@]}" > 0 )); then
        stage_binaries "${staging}" "${bins[@]}"
    fi
}

main "$@"
