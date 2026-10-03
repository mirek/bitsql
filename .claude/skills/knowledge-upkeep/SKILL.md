---
name: knowledge-upkeep
description: Where each kind of new knowledge goes in bitsql (roadmap status, design decisions, fidelity traps, protocol/T-SQL/tedious/MoonBit findings, reuse inventory) so docs and skills stay current. Use at the end of every work iteration before committing, and whenever something surprising is learned about SQL Server, tedious, TDS or MoonBit.
---

# Keeping project knowledge current

Docs rot unless updates ride along with the code. Before each commit, ask:
*what did I learn that the next session would otherwise rediscover?*, and put
it in exactly one place:

| You learned… | Put it in |
| --- | --- |
| A roadmap item is done, partly done, or newly discovered | `docs/design/roadmap.md` checkboxes |
| The design changed or a draft assumption was wrong | `docs/design/decisions.md` (dated entry) + fix the topic page |
| A behavior where a plausible implementation diverges from SQL Server | `docs/design/fidelity-traps.md` row + corpus case |
| TDS wire detail, token order, byte layout | `.claude/skills/tds-protocol/SKILL.md` → "bitsql findings" |
| T-SQL semantics, error numbers/classes, conversions | `.claude/skills/t-sql/SKILL.md` → "bitsql findings" |
| Catalog view contracts | `.claude/skills/sys/SKILL.md` → "bitsql findings" |
| tedious / mssql client behavior | `.claude/skills/tedious/SKILL.md` → "bitsql findings" |
| MoonBit language/tooling surprise | `.claude/skills/moonbit/SKILL.md` → "Gotchas and learnings" |
| Something ported (or deliberately not) from msduck/mssqlite | `docs/reuse/README.md` checklist |
| How to run/extend the harness changed | `.claude/skills/harness/SKILL.md` |
| A repeatable workflow emerged that no skill covers | a new `.claude/skills/<name>/SKILL.md` + a line in `CLAUDE.md` |
| User preference about how to work | Claude memory, not the repo |

Rules:

- Findings are dated (`2026-10-03:`), one short paragraph, and cite evidence
  (test name, capture file, or tedious source line).
- An inherited note proven wrong gets corrected in place, plus a finding saying
  what was wrong.
- Don't duplicate: link instead. Code facts derivable from the source don't
  belong in docs.
- Keep `CLAUDE.md` short. It routes to skills and should not absorb their
  content.
- Skill frontmatter `description` decides when a skill triggers. When a skill's
  scope grows, update its description.
