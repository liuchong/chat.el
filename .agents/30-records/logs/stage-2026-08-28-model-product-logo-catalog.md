# Stage: Model Product Logo Catalog

- Type: log
- Attention: record
- Status: done
- Scope: project
- Date: 2026-08-28
- Tags: prompt, providers, logos, product-identity

## What Changed

The prompt logo catalogue now treats a model product as the visual identity.
Parent companies, transport variants, former names and common provider names
resolve through aliases to that product.  The catalogue also includes likely
future providers, so adding one normally requires only a `:vendor` declaration.

Qwen was updated from its former geometric mark to its current folded-ribbon
mark.  Gemini remains the four-point spark.  GLM follows its current Z-shaped
identity, and MiMo now has a dedicated product mark.

## Reusable Lessons

A provider, a vendor and a model product are three different identities.
Transport uses the provider, configuration groups by vendor, and the prompt
should show the model product the developer selected.  Using the parent company
logo may be factually related while still being visually wrong.

Logo coverage also needs aliases.  A directory full of correct files is not
automatic if `xiaomi-mimo`, `xiaomimimo` and `mimo` are treated as unrelated
keys.  Keep one canonical asset per product and resolve every alternate name to
it before lookup.
