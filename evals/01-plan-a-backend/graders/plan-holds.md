---
type: llm
focus: {source: file, path: plan.md}
---
- Each capability is a service that owns its data; no service reads another's database, and data crosses services only through their gRPC contracts.
- One service issues every access token, and the others verify it.
- Releasing an unchecked booking at 10:00 is durable work owned by the bookings service, such as a Temporal workflow or timer per booking, and the deadline uses each location's time zone.
- Bookings are confined by row-level security for both the member and the company, and the plan says how a member's own reads and writes stay limited to that member while office managers act on their company's bookings.
- The plan lists open questions for the user, each with the answer it assumes.
