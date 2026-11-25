# Native OpenCode plugin coexistence and recovery

The installed OpenCode Desktop PE/ASAR package 1.18.11 was exercised through its
unmodified bundled backend under Electron 42.3.3/Node 24.15.0. The normal stock
headless client marker is `cli`; backend health reports version `local`. Neither
value was overridden. This qualifies the exact bundled backend/plugin event
route, not Desktop GUI, another OpenCode CLI or model execution.

Inputs were frozen C4 source `6c651f9b164ae1932c65bab661de315640017e83` and fork
`9ec86f75343ba4eded66e2085f097ff4baab7d67`. The private managed structural fixture
kept Codex membership throughout; loading OpenCode integrations did not attach
OpenCode. It is not an initialized 1C stand or an installed-candidate receipt.
All HOME/XDG/Windows-profile/npm/Git-config targets were private; ordinary
credentials, global settings, 1C and model/provider requests were unused.

Standard pinned npm dependency preparation was performed without lifecycle
scripts: project SDK/plugin 1.18.4 from C4's lock, private runtime SDK/plugin
1.18.11, with exact integrity/lock evidence. Host installation, plugin loading
and event delivery were not mocked or rewritten.

## Original three-phase execution

1. Stock health/config/tool registry and a real `POST /session` returned 200.
   Both `itl_create_dev_workspace` and `itl_close_dev_workspace` registered beside
   standard native tools. Direct production wrapper `ensure` returned 0. All
   3,733 project files retained their post-preparation hashes.
2. Only the owned fixture's rules pin was made malformed. The real event called
   the wrapper, which exited 1 with `ONEC_RULES_ENSURE_FAILED` and
   `ITL_PLUGIN_RULES_PIN_MISSING`, including exact Unicode/space paths. The HTTP
   request returned 200 before the asynchronous hook rejection. The stock host
   does not await the hook promise; its unhandled rejection ended this backend
   with exit 1. This is the retained native failure mode, not a successful event.
3. After byte-exact pin restoration, one stock backend relaunch used the SAME
   project, private profile, dependency locks and runner/module. The real session,
   config/tool registry and direct wrapper `ensure` passed. The host stayed alive
   after the restored event and its ordinary listener stop exited 0. The complete
   project, 37 source scripts and controlled plugin tree were unchanged.

Production success stdout is internally captured. A success event console marker
is therefore not claimed; real event delivery is causally demonstrated by the
controlled invalid-pin phase. Project version independence, read-only ensure,
no implicit attachment, coexistence and surfaced failure/recovery meet PL1–PL3
for this exact host route. No fork or host patch was made to hide the fault.

## Artifacts and limits

Owned area: `build/OpenCode headless проверка d7724b5b75cc42979c6c3d0ddebbc66b`.

| Artifact | SHA256 |
| --- | --- |
| `native-coexistence-report.json` | `8087d8aea423b11f8ffa837fdf8cf90bd27a016e96fd52835a735cdb4928e050` |
| `native-recovery-report.json` | `9b112937a215af7fbfd132e3446a2c4f2af2a17c6ad536d42e9ac721c9463f85` |
| Original native stderr | `07b4504e4fd8824df4551520b01234c940804cf95dcbcd21290631faf0f34aea` |
| Unmodified backend bundle | `d87082b3f5f8a52f7a3ef4af940e2a9392f781919856c0dd72b36246947906ee` |
| `qualification-summary.md` | `3df40c3a976285119ad5559dc850075240eeef839463bf7fa7b612ad563a3cc3` |

The stock runner and first-time/recovery reproducers, raw API bodies, npm locks,
hash inventories and original logs remain in this area. A future requalification
must preserve its Unicode/space topology and actual host/event fault route.

Desktop UI/error presentation/automatic respawn, a separate OpenCode CLI,
workspace-tool execution, OpenCode disable/uninstall UI and native hooks in other
hosts remain unverified. Existing Codex marketplace/discovery/persisted disable
and removal have their separate receipts; publication is still task 10.6.
No minimum supported version is inferred from this single observed package.

Automatic approval review rejected removal of the private npm cache with only
`blocked by policy` as its reason. No deletion or bypass occurred. The temporary
research budget was instead enlarged to 384 MiB; the retained area is about
219 MB and C: free space stayed above 2 GiB. Earlier surfaced Python stdout lacked
explicit UTF-8; original native bytes/paths were intact, and the explicit UTF-8
repeat passed the same Unicode/space round trip. Neither event failure nor
transport diagnostics were erased.
