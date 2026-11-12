---
type: llm
focus: {source: file, path: plan.md}
---
- One service issues every access token and owns the workspaces and who belongs to each, and it checks a person's membership before naming a workspace in their token.
- A token names at most one workspace, the one its session acts for. Switching workspaces takes a new token from the issuer, proved by the refresh token; no request field or header chooses the workspace.
- Projects and tasks are tenant tables confined by row-level security to the workspace the session acts for, and use cases read the workspace from the caller's token, never from their input.
- Inviting someone who isn't a member yet runs, in the service that owns memberships, on a database role that isn't confined to one tenant.
- The plan lists open questions for the user, each with the answer it assumes.
