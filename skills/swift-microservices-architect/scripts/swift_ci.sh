#!/usr/bin/env bash
#
# Runs swift build or swift test with the flags CI holds every change to. Run it from a
# package's root, with --library first for a library, whose public types state Sendable:
#
#     swift_ci.sh [--library] <build|test> [arguments…]
#     swift_ci.sh test
#     swift_ci.sh --library test --filter BookshelfAuthenticationTests

set -eu

flags="-Xswiftc -warnings-as-errors --explicit-target-dependency-import-check error"

if [ "${1:-}" = "--library" ]; then
    flags="$flags -Xswiftc -require-explicit-sendable"
    shift
fi

case "${1:-}" in
build | test) ;;
*)
    echo "usage: swift_ci.sh [--library] <build|test> [arguments…]" >&2
    exit 2
    ;;
esac

command=$1
shift

if [ ! -f Package.swift ]; then
    echo "swift_ci.sh runs from a package's root, beside Package.swift" >&2
    exit 2
fi

# shellcheck disable=SC2086
exec swift "$command" $flags "$@"
