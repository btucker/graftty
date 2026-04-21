# Graftty — Agent Instructions

## Keep SPECS.md in sync with behavior

Every PR that adds, changes, or removes user-visible functionality must also update `SPECS.md`. SPECS.md is the authoritative description of what the app does — code without a spec entry is not done.

Write requirements in the EARS (Easy Approach to Requirements Syntax) style already established in SPECS.md:

- **State-scoped:** "While `<state>`, the application shall `<behavior>`."
- **Event-scoped:** "When `<trigger>`, the application shall `<behavior>`."
- **Conditional:** "If `<condition>`, then the application shall `<behavior>`."

Each requirement gets a scoped identifier (e.g., `GIT-4.3`, `LAYOUT-2.12`) so it can be cited in PRs and commit messages. Place new requirements under the feature section they concern (context-menu items go under their feature's section, not in a central "context menu" cluster) and extend the existing numbering rather than renumbering siblings.

If a change removes or modifies behavior, update or delete the matching requirements in the same commit — the goal is that SPECS.md never lags behind the code.
