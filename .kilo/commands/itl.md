---
description: Show available ITL 1C workflow actions
agent: code
---

Show this short ITL menu:

```text
/itl-new-config-branch <name>     Create a configuration development branch worktree.
/itl-new-extension-branch <name>  Create an extension development branch worktree.
/itl-set-dev-branch-extension <name>
                                  Set the extension name for the current extension branch.
/itl-dump-dev-branch-extension    Dump extension files from the current branch infobase.
/itl-status                       Show branch, infobase, and verification status.
/itl-update-base                  Update the current branch infobase from branch files.
/itl-verify                       Update the branch base, then run Vanessa tests.
/itl-refresh                      Merge fresh master into the current branch.
/itl-result                       Export CF/CFE without closing the branch.
/itl-close                        Export final CF/CFE and close the branch.
/itl-switch <master|branch name>  Show/open worktree or switch a legacy branch.
```

Do not execute a lifecycle action unless the user clearly chooses one. Detailed helper actions exist for diagnostics, but do not show them in the beginner menu.
