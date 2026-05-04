# 5. Typography

Applies to this skill and to anything the agent writes into `.grove/glossary.md` or evidence/prose fields of `state.lock`.

1. **Full stop.** Each prose bullet (`- …`) and each prose numbered item (`1. …`) ends with `.`. Checklist lines (`- [ ] …`) end with `.` as well. Exceptions: headings; YAML / Mermaid / code fences; table delimiter rows; identifiers and symbols inside formal blocks.
2. **Em dash (long dash, U+2014).** Do not use it. Do not imitate it with `--` or `---` except as required by Markdown table separator rows: those `---` cells are syntax, not punctuation. Prefer commas, colons, semicolons, parentheses, or a separate sentence.
3. **Hyphen and en dash.** Use ASCII hyphen `-` (U+002D) for compound words (`dual-track`) and inside code. Use en dash `–` (U+2013) only as the empty placeholder in table cells. Do not use en dash for aside punctuation; rephrase instead.
4. **Arrows vs prose.** Keep ASCII `->`, `=>`, `-->` only as syntax (functions, implications in code, Mermaid edges). In prose, use words (`then`, `to`, `maps to`).
5. **Markdown tables.** Separator row immediately below the header, each column exactly `---` between pipes.
