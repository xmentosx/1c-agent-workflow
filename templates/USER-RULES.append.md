## 1C Project Lifecycle

Use `.agents/skills/1c-workflow/SKILL.md` for project initialization, feature start, feature refresh, feature load, master sync, feature listing, branch switching, feature finish, and CF export.

Use `FEATURE-DEVELOPMENT.ru.md` for the development process inside a feature branch: quick-fix for small local fixes, OpenSpec for feature work or risky behavior changes.

Do not edit installer-managed `AGENTS.md` directly. Store secrets only in local `.dev.env`.

Feature changes must be loaded only into the feature infobase copy, never directly into the source infobase connected to 1C configuration repository storage.
