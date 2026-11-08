# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

This repo keeps a **glossary only**. It does not use ADRs, and skills should not create them, suggest them, or look for `docs/adr/`.

## Before exploring, read this

- **`GLOSSARY.md`** at the repo root.

If it doesn't exist, **proceed silently**. Don't flag its absence; don't suggest creating it upfront. The `/domain-modeling` skill (reached via `/grill-with-docs` and `/improve-codebase-architecture`) creates it lazily when terms actually get resolved.

## File structure

```
/
├── GLOSSARY.md
└── (repo source)
```

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a test name), use the term as defined in `GLOSSARY.md`. Don't drift to synonyms the glossary explicitly avoids.

If the concept you need isn't in the glossary yet, that's a signal: either you're inventing language the project doesn't use (reconsider) or there's a real gap (note it for `/domain-modeling`).

## Record decisions in the glossary

Where the seed setup would say "write an ADR", this repo instead keeps a short entry in `GLOSSARY.md`: the term, and one line on the decision or constraint behind it. Anything longer belongs in a code comment or the README.
