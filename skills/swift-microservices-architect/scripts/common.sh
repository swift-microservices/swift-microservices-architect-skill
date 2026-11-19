# Shared by check_boundaries.sh and check_style.sh, which load it with `.`; not run on its own.

failed=0

# report <rule> <violations>: prints the rule and its violations, if it has any.
report() {
    if [ -n "$2" ]; then
        echo "FAIL $1"
        echo "$2" | sed 's/^/  /'
        failed=1
    fi
}
