---
type: llm
focus: {source: file, path: plan.md}
---
- Each capability is a service that owns its data; no service reads another's database, and data crosses services only through their gRPC contracts.
- One service issues every access token and owns the companies and who belongs to each. It checks membership before naming a company in a token, and switching companies takes a new token from it, proved by the refresh token.
- Bookings are confined by row-level security, and the plan keeps a member's own reads and writes to that member while office managers act on their company's bookings.
- Adding a person who isn't yet in a company runs, in the service that owns memberships, on a database role that isn't confined to one tenant.
- Releasing an unchecked booking at 10:00 is durable work owned by the bookings service, such as a Temporal workflow per booking.
- The plan ends with open questions for the user, each with the answer it assumes.
