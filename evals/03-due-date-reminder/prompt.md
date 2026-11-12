---
max_turns: 60
timeout_seconds: 900
allowed_tools: [Skill, Read, Glob, Grep, Write, Edit]
---
In our Bookshelf backend, email a member two days before one of their loans is due, and don't remind them about a loan they've already returned. Loans already run a LoanWorkflow per loan. The code isn't checked out here: write every file the change adds or changes at its path under bookshelf-loans/, with whole new files and only the changed declarations of changed ones. Don't stop to ask me anything.
