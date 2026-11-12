---
type: llm
focus: last_message
---
- Only bookshelf-core is built and tested with `--library` (or `-require-explicit-sendable`); bookshelf-loans is tested without it, with a Postgres for its Postgres tests.
- The secrets are `PACKAGES_TOKEN`, only where a package has private dependencies, and `DOKPLOY_URL` and `DOKPLOY_TOKEN` for the service.
- One Dokploy application runs `serve --migrate-database` at a single replica and deploys first; no other serving replica runs migrations or holds the database owner's certificate.
- Production deploys only an image staging already ran, by hand.
