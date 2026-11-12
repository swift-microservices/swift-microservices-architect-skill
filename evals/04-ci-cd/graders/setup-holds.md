---
type: llm
focus: last_message
---
- The secrets are `PACKAGES_TOKEN`, only where a package has private dependencies, and `DOKPLOY_URL` and `DOKPLOY_TOKEN` for the service.
- One Dokploy application runs `serve --migrate-database` at a single replica and deploys first, and only it mounts the migrator's certificate.
