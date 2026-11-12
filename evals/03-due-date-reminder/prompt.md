---
max_turns: 80
timeout_seconds: 1500
allowed_tools: [Skill, Read, Glob, Grep, Write, Edit]
---
In our Bookshelf backend, email a member two days before one of their loans is due, and don't remind them about a loan they've already returned. Loans already run a LoanWorkflow per loan. The code isn't checked out here: write every file the change adds or changes under bookshelf-loans/, with whole new files and only the changed declarations of changed ones. Don't stop to ask me anything.
