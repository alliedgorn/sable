# Lesson: Gatekeeper Communication Patterns

**Date**: 2026-03-27
**Source**: Session 4 — first day as Gorn's gatekeeper

## Pattern

When managing a queue for a principal (Gorn), the gatekeeper's most important output is **immediate acknowledgment** to requesters. "Already logged" within seconds prevents follow-up DMs and duplicate routing.

## Key Insights

1. **Redundant routing is healthy** — Multiple Beasts (Zaghnal + Leonard) reporting the same item means the system has no single point of failure. Acknowledge both, don't complain about duplication.

2. **Don't pre-log before spec exists** — Creating a Prowl task for "approve spec when submitted" and then another when it arrives creates noise. Wait for the actual submission.

3. **Supersession over deletion** — When a revised spec replaces an earlier one, create a new Prowl task noting it supersedes the old one. Don't try to edit or delete the old task (Nothing is Deleted).

## Application

- Reply to routing DMs within one message cycle
- Use "Already logged — Prowl task #X" as the standard acknowledgment
- Only create Prowl tasks when the actual artifact (spec, doc, etc.) exists
