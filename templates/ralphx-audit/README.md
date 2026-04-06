# Audit Workspace Example

A reusable workspace template for auditing any codebase with ralphx.

## Usage

```bash
# Copy into your project
ralphx init audit
cp examples/audit/* .ralphx/audit/

# Edit AGENT.md with your repo's test/build commands
# Edit prd.json acceptance criteria for your project
# Adjust .ralphxrc budget and model settings

# Run the audit
ralphx run audit --verbose
```

## What's included

- **PROMPT.md** — Audit prompt with the simplicity invariant: the agent verifies rather than over-engineers
- **prd.json** — 7 stories covering docs, testing, correctness, UX, production readiness, coherence, and security
- **AGENT.md** — Template for repo-specific agent instructions
- **.ralphxrc** — Config: Sonnet model, convergence threshold 2, $50 budget

## Design principles

Acceptance criteria are written as **verification questions** ("Confirm X is correct") not implementation mandates ("Add X"). This prevents the audit agent from adding unnecessary complexity.

The prompt includes a "What NOT to fix" section that's as detailed as "What to fix" — this is critical for preventing scope creep.
