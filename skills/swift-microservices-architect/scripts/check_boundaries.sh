#!/usr/bin/env bash
#
# Checks what SPM can't about a service's boundaries. Run it from the service's root:
#
#     check_boundaries.sh <X> <Org>
#     check_boundaries.sh Loans Bookshelf
#
# Prints each violation under the rule it breaks, and exits 1 if there is any.

set -u

if [ "$#" -ne 2 ]; then
    echo "usage: check_boundaries.sh <X> <Org>" >&2
    exit 2
fi

if [ ! -d Sources ] || [ ! -f Package.swift ]; then
    echo "check_boundaries.sh runs from a service's root, beside Package.swift and Sources/" >&2
    exit 2
fi

service=$1
org=$2
core="Sources/${service}Core"
grpc="${service}GRPC"
executable="Sources/${service}"
import_prefix='^(package |public )?import'
temporal_import="${import_prefix} Temporal\$"
failed=0

# report <rule> <violations>: prints the rule and its violations, if it has any.
report() {
    if [ -n "$2" ]; then
        echo "FAIL $1"
        echo "$2" | sed 's/^/  /'
        failed=1
    fi
}

report "Core imports no adapter technology or contract" "$(
    grep -rlE "${import_prefix} (GRPC[A-Za-z]*|Hummingbird[A-Za-z]*|PostgresNIO|PersistencePostgres|Valkey|Configuration|ServiceLifecycle|SwiftProtobuf|AsyncHTTPClient|[A-Za-z]+Protos)\$" "$core" 2>/dev/null
)"

report "Temporal stays out of the adapter targets" "$(
    grep -rlE "$temporal_import" Sources 2>/dev/null | grep -vE "^Sources/(${service}Core|${service})/"
)"

report "Inside Core, only Workflows/ and use case implementations import Temporal" "$(
    grep -rlE "$temporal_import" "$core" 2>/dev/null | grep -vE "^${core}/Workflows/|/UseCases/[^/]+/[^/]+UseCase\.swift\$"
)"

report "A use case that imports Temporal names TemporalClient" "$(
    grep -rlE "$temporal_import" "$core" 2>/dev/null | grep '/UseCases/' | while read -r file; do
        grep -q 'TemporalClient' "$file" || echo "$file"
    done
)"

report "Only the executable builds a Temporal client or worker" "$(
    grep -rnE '(^|[^A-Za-z])(TemporalClient(\.connect)?|TemporalWorker)\(' Sources 2>/dev/null | grep -v "^${executable}/"
)"

report "An activity container stores only use case and port protocols and a Logger" "$(
    grep -rnE --include='*Activities.swift' '^    (private |package )?(let|var) [A-Za-z]+:' "$core/Workflows" 2>/dev/null |
        grep -E ': ([A-Z]|any [A-Za-z]*(Repository|Database|Scope)$)' |
        grep -v ': Logger$'
)"

report "Activities call system use cases only, so nothing in Workflows/ names a caller" "$(
    grep -rnE 'subject:|UserIdentity' "$core/Workflows" 2>/dev/null
)"

# Lives in a function because macOS's bash 3.2 can't parse a case inside $(…).
own_module_imports() {
    for target in Sources/*/; do
        target=${target%/}
        name=${target#Sources/}
        case "$name" in
        "$service") continue ;;
        "${service}Core") allowed='__none__' ;;
        "$grpc") allowed="${service}Core|${service}Protos" ;;
        *) allowed="${service}Core" ;;
        esac
        grep -rnE "${import_prefix} ${service}[A-Za-z]+\$" "$target" 2>/dev/null | grep -vE "import (${allowed})\$"
    done
}

report "Adapters import no sibling adapter, and only ${grpc} imports the contract" "$(own_module_imports)"

report "Generated contract types stay in ${grpc} and the executable" "$(
    grep -rlE "${org}_[A-Za-z]+_V[0-9]+_" Sources 2>/dev/null | grep -vE "^Sources/(${grpc}|${service})/"
)"

report "Only the executable reads configuration" "$(
    grep -rlE "${import_prefix} Configuration\$" Sources 2>/dev/null | grep -v "^${executable}/"
)"

report "Every Foundation import is the conditional one" "$(
    grep -rlE '^(@[A-Za-z_]+ )*([a-z]+ )*import( [a-z]+)? Foundation(\.|$)' Sources 2>/dev/null | while read -r file; do
        grep -q 'canImport(FoundationEssentials)' "$file" || echo "$file"
    done
)"

report "No unstructured tasks" "$(
    grep -rnE '(^|[^A-Za-z.])Task(\.detached)? *[({]' Sources 2>/dev/null
)"

report "Every use case protocol has typed throws" "$(
    for file in "$core"/*/UseCases/*/*UseCaseProtocol.swift; do
        [ -f "$file" ] || continue
        grep -q 'throws(' "$file" || echo "$file"
    done
)"

report "No package defaults to the main actor" "$(grep -n 'defaultIsolation' Package.swift)"

unchecked=$(grep -rnE -B1 '@unchecked Sendable|nonisolated\(unsafe\)|@preconcurrency' Sources 2>/dev/null)
if [ -n "$unchecked" ]; then
    echo "REVIEW each is in an adapter target, with its reason on the line above"
    echo "$unchecked" | sed 's/^/  /'
fi

if [ "$failed" -eq 0 ]; then
    echo "Boundary checks passed."
fi

exit "$failed"
