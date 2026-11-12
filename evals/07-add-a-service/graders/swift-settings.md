---
type: regex
target: {source: file, path: bookshelf-reviews/Package.swift}
flags: s
weight: 0.5
---
^(?=.*ExistentialAny)(?=.*MemberImportVisibility)(?=.*InternalImportsByDefault)(?=.*NonisolatedNonsendingByDefault)
