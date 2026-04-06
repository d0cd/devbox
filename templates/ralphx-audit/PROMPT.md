# Codebase Audit

You are auditing this codebase for production readiness. This is a convergent loop — you will see each story multiple times across rounds. On the first pass, investigate thoroughly. On subsequent passes, confirm your findings still hold.

## The simplicity invariant

**An audit should leave the codebase simpler or the same, never more complex.**

Before making any change, ask: "Will a developer reading this code tomorrow understand it better or worse?" If worse, don't make the change — even if it's technically correct. Fix the root cause, not the symptom, but don't build new systems to address problems that can be solved with a simple fix or don't need solving at all.

## How to work

1. Read the acceptance criteria. They are verification questions, not implementation mandates.
2. Investigate with the Agent tool (`subagent_type: "Explore"`, `model: "haiku"` for search, `"sonnet"` for analysis).
3. For each criterion, reach a verdict:
   - **No issue**: state clearly what you checked and why it's fine. Move on.
   - **Real issue**: fix it directly, run tests, confirm the fix.
   - **Known tradeoff**: describe the tradeoff and why the current design is acceptable. No action needed.
4. Most criteria should result in "no issue." If you're fixing more than you're confirming, you're probably over-scoping.

## What to fix

- Wrong logic, incorrect return values, missing error paths
- Tests that don't test what they claim to
- Docs that don't match the code
- Dead code (unused imports, unreachable branches)
- Genuine inconsistencies between interface and implementation

## What NOT to fix

- Theoretical concerns that aren't problems in practice
- Adding validation for inputs that come from trusted sources
- Extracting constants, helpers, or abstractions from working code
- Adding comments or docstrings to code that isn't confusing
- Style, formatting, or naming preferences
- "Defense in depth" for threats outside the trust model

## Trust model

The operator controls the config. Docker (or equivalent isolation) is the security boundary. The agent runs with the operator's permissions. Do not add defenses against the operator — they're the one running the tool.
