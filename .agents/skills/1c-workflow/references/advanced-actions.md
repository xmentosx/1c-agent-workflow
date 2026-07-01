# Advanced Helper Actions

This reference is for diagnostics, recovery, and automation. Do not show this full list as the beginner command surface.

Run helper actions from the project root:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action <action>
```

Common internal actions:

```text
init-project
validate
check-tools
list-platforms
detect-apache
install-apache
install-vanessa-automation
sync-master
new-dev-branch
new-extension-dev-branch
set-dev-branch-extension
dump-dev-branch-extension
activate-dev-branch-context
update-dev-branch-base
run-dev-branch-tests
verify-dev-branch
refresh-dev-branch
export-dev-branch-result
close-dev-branch
switch-master
switch-dev-branch
list-dev-branches
status
```

For normal developer work, prefer the short `/itl-*` commands documented in the README and developer guide.
