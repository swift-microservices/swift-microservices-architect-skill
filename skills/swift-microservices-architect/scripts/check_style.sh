#!/usr/bin/env bash
#
# Checks the code style rules a script can see in a package's sources. Run it from the
# package's root, beside Package.swift and Sources/:
#
#     check_style.sh
#
# Prints each violation under the rule it breaks, and exits 1 if there is any. Then lists
# repository methods and test files for review, without failing.

set -u

if [ "$#" -ne 0 ]; then
    echo "usage: check_style.sh" >&2
    exit 2
fi

if [ ! -d Sources ] || [ ! -f Package.swift ]; then
    echo "check_style.sh runs from a package's root, beside Package.swift and Sources/" >&2
    exit 2
fi

failed=0

# report <rule> <violations>: prints the rule and its violations, if it has any.
report() {
    if [ -n "$2" ]; then
        echo "FAIL $1"
        echo "$2" | sed 's/^/  /'
        failed=1
    fi
}

# swift_files <find arguments>: lists the Swift files under Sources/ that match, one per line.
swift_files() {
    find Sources -type f -name '*.swift' "$@" | sort
}

# run_awk <program> <files>: runs the program over the files, if there are any.
run_awk() {
    program=$1
    files=$2
    [ -n "$files" ] || return 0
    echo "$files" | tr '\n' '\0' | xargs -0 awk "$program"
}

# Joins a call's wrapped arguments, as check_skill.py does for the skill's examples, and
# finds a try or await that starts an argument.
effects_in_arguments='
function flush() {
    if (joined ~ /(\(|[A-Za-z0-9_]: |, )(try|await) /) {
        print file ":" start ": " joined
    }
    joined = ""
}
FNR == 1 { flush(); in_string = 0 }
{
    line = $0
    quotes = gsub(/"""/, "&", line)
    if (quotes % 2 == 1) { in_string = !in_string; flush(); next }
    if (in_string) next

    code = $0
    gsub(/"([^"\\]|\\.)*"/, "\"\"", code)
    sub(/\/\/.*$/, "", code)
    sub(/^[[:space:]]+/, "", code)
    sub(/[[:space:]]+$/, "", code)

    if (joined != "" && (joined ~ /[(,]$/ || code ~ /^\)/)) {
        separator = (joined ~ /\($/ || code ~ /^\)/) ? "" : " "
        joined = joined separator code
    } else {
        flush()
        joined = code
        file = FILENAME
        start = FNR
    }
}
END { flush() }
'

report "Build, then call: no try or await inside a call's arguments" "$(
    run_awk "$effects_in_arguments" "$(swift_files)"
)"

# The first string after logger.error( in a use case, on its line or a following one.
unknown_error_messages='
FNR == 1 { pending = 0 }
{
    line = $0
    if (!pending) {
        position = index(line, "logger.error(")
        if (position == 0) next
        pending = 1
        start = FNR
        line = substr(line, position + 13)
    }
    if (match(line, /"[^"]*"/)) {
        message = substr(line, RSTART + 1, RLENGTH - 2)
        if (message !~ /^[A-Z][A-Za-z -]* failed: unknown error$/) {
            print FILENAME ":" start ": " message
        }
        pending = 0
    }
}
'

report "A use case's error line reads \"<Activity> failed: unknown error\"" "$(
    run_awk "$unknown_error_messages" "$(swift_files -name '*UseCase.swift')"
)"

# Declarations of a type at the file's top level, outside multi-line strings.
top_level_types='
function finish() {
    if (count > 1) print file ": " names
    count = 0
    names = ""
}
FNR == 1 { finish(); in_string = 0; file = FILENAME }
{
    line = $0
    quotes = gsub(/"""/, "&", line)
    if (quotes % 2 == 1) { in_string = !in_string; next }
    if (in_string) next

    if ($0 ~ /^((@[A-Za-z]+(\([^)]*\))?|public|package|internal|private|fileprivate|open|final|indirect|nonisolated) +)*(struct|enum|class|actor|protocol) +[A-Z]/) {
        name = $0
        sub(/^.*(struct|enum|class|actor|protocol) +/, "", name)
        sub(/[^A-Za-z0-9_].*$/, "", name)
        names = (count == 0) ? name : names ", " name
        count++
    }
}
END { finish() }
'

report "One top-level type per file" "$(
    run_awk "$top_level_types" "$(swift_files)"
)"

# A ConfigReader read names its key first; a root reads only its own keys, and a reader
# (Configuration/, Type+ConfigReader.swift) reads the rest.
configuration_reads='
{
    line = $0
    while (match(line, /[A-Za-z_]\(forKey: *[^,)]*/)) {
        argument = substr(line, RSTART + 2, RLENGTH - 2)
        line = substr(line, RSTART + RLENGTH)
        sub(/^forKey: */, "", argument)
        key = argument
        if (key ~ /^"[^"]*"$/) {
            key = substr(key, 2, length(key) - 2)
            if (key ~ /^(logLevel|host|port|db|worker\.taskqueue)$/) continue
            if (key ~ /(^|\.)(user|password)$/) continue
        }
        print FILENAME ":" FNR ": " argument
    }
}
'

report "Configuration is read in a reader in Configuration/, except a root's own keys" "$(
    run_awk "$configuration_reads" "$(swift_files ! -path '*/Configuration/*' ! -name '*+ConfigReader.swift')"
)"

# lines <pattern> <find arguments>: prints file:line: text for each matching line.
lines() {
    pattern=$1
    shift
    files=$(swift_files "$@")
    [ -n "$files" ] || return 0
    echo "$files" | tr '\n' '\0' | xargs -0 grep -nE "$pattern" /dev/null | sed -E 's/:[[:space:]]+/: /'
}

report "Absence is an optional or a nullable column, never \"\", -1, a distant date or DEFAULT ''" "$(
    lines '\?\? *(""|-1([^0-9]|$))|\.distant(Past|Future)|DEFAULT '"''"
)"

report "A create's insert is plain, with no ON CONFLICT; a retry is found by its key first" "$(
    lines '[Oo][Nn] +[Cc][Oo][Nn][Ff][Ll][Ii][Cc][Tt]' -path 'Sources/*Postgres/*' -name 'Create*Statement.swift'
)"

report "A policy is a predicate on the tenant and reads no role" "$(
    lines "current_setting\\('[^']*role" -path 'Sources/*Postgres/*'
)"

# A repository method in Core with two parameters or more, none of them a command and none
# a page size, printed as one line.
repository_methods='
# A read is named for what it returns: loan(userID:idempotencyKey:) -> Loan?, activeLoans(userID:) -> [Loan].
function is_read(    name, returned) {
    if (declaration !~ /->/) return 0
    name = declaration
    sub(/^.*func +/, "", name)
    sub(/[^A-Za-z0-9_].*$/, "", name)
    if (name ~ /^(create|insert|add|update|set|mark|save|store|replace|remove|delete|end|revoke|lock)([A-Z]|$)/) return 0
    returned = declaration
    sub(/^.*-> */, "", returned)
    gsub(/[^A-Za-z0-9_]/, " ", returned)
    sub(/^ *(KeyedPage|Page) +/, "", returned)
    sub(/^ +/, "", returned)
    sub(/ .*$/, "", returned)
    if (returned == "") return 0
    return index(tolower(name), tolower(returned)) > 0
}
function analyze(    rest, depth, i, c, previous, parameters, count) {
    rest = substr(declaration, index(declaration, "(") + 1)
    depth = 1
    parameters = ""
    previous = ""
    for (i = 1; i <= length(rest); i++) {
        c = substr(rest, i, 1)
        if (c == "(" || c == "[" || c == "<") depth++
        else if (c == ")" || c == "]" || (c == ">" && previous != "-")) {
            depth--
            if (depth == 0) break
        }
        if (c == "," && depth == 1) count++
        parameters = parameters c
        previous = c
    }
    if (parameters ~ /^[[:space:]]*$/) return
    if (count < 1) return
    if (parameters ~ /Command/ || parameters ~ /pageSize:/) return
    if (is_read()) return
    gsub(/[[:space:]]+/, " ", declaration)
    gsub(/\( /, "(", declaration)
    gsub(/ \)/, ")", declaration)
    sub(/^ /, "", declaration)
    sub(/ *\{.*$/, "", declaration)
    print FILENAME ":" start ": " declaration
}
/^[[:space:]]*(package |public )?func / {
    collecting = 1
    declaration = ""
    depth = 0
    opened = 0
    start = FNR
}
collecting {
    declaration = declaration " " $0
    line = $0
    opens = gsub(/\(/, "(", line)
    closes = gsub(/\)/, ")", line)
    depth += opens - closes
    if (opens > 0) opened = 1
    if (opened && depth <= 0) {
        analyze()
        collecting = 0
    }
}
'

repository_files=$(swift_files -path 'Sources/*Core/*' -name '*Repository.swift')
repository_review=$(run_awk "$repository_methods" "$repository_files")
if [ -n "$repository_review" ]; then
    echo "REVIEW each is a read; a write that takes more than an id takes a command"
    echo "$repository_review" | sed 's/^/  /'
fi

# A test file outside Mocks/ and Support/ named for no type's file in Sources/.
unmatched_tests=$(
    [ -d Tests ] || exit 0
    find Tests -type f -name '*Tests.swift' ! -path '*/Mocks/*' ! -path '*/Support/*' | sort | while read -r file; do
        tested=$(basename "$file" Tests.swift)
        [ -n "$(find Sources -type f -name "${tested}.swift" | head -n 1)" ] || echo "$file"
    done
)
if [ -n "$unmatched_tests" ]; then
    echo "REVIEW each test file is named for the one type it tests"
    echo "$unmatched_tests" | sed 's/^/  /'
fi

if [ "$failed" -eq 0 ]; then
    echo "Style checks passed."
fi

exit "$failed"
