---
max_turns: 25
timeout_seconds: 300
allowed_tools: [Skill, Read, Glob, Grep]
---
Our Swift server has a gateway in front of a few gRPC services. The service that sends our emails needs delivery-status webhooks from our email provider. Where does each piece of this go, and what does each piece do? Answer with short code sketches; don't write any files, and don't stop to ask me anything.
