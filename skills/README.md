# Workspace skills

Drop **workspace-level skills** here — reusable analysis procedures that span
multiple DEFRA service repos (e.g. "audit test coverage across services",
"trace a request through UI → GAS → CW → agreements"). These apply to the
cross-service workspace, not to any single service repo.

## Adding a skill

Create one directory per skill containing a `SKILL.md`:

```
skills/
  my-analysis/
    SKILL.md        # frontmatter (name, description) + instructions
    ...             # optional supporting scripts/templates
```

The `SKILL.md` frontmatter (`name`, `description`) is what Claude uses to decide
when the skill is relevant, so make the description specific about the trigger.
