# Vanessa Authoring Examples

These files support `references/vanessa-recipes.md`.

- `unit-like.feature` is product-neutral and may be syntax-checked unchanged.
- Files tagged `@template` are copy-and-adapt patterns. Replace every `<...>`
  marker, remove `@template`, validate exact steps/selectors in the current
  project, and place the resulting scenario under `tests/features`.

They are not installed as application tests and must not be added wholesale to a
verification run.
