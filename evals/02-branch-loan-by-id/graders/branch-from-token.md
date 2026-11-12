---
type: llm
focus: trace
---
- The use case checks that the caller is a librarian and reads the branch from the caller's token (`subject.organizationID`) before anything else, throwing a forbidden case otherwise.
- Neither the RPC's request nor the use case's input carries a branch id or a user id; the only id it takes is the loan's.
- The use case runs on the tenant database, where the branch's row-level security policy confines what it reads, and a loan outside the branch answers as not found.
- The handler maps every error case to a gRPC status, and the gateway's route sits in the tier for a signed-in caller.
