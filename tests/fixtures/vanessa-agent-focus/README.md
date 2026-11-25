# Vanessa agent launch focus regression

The probes execute production BSL taken from the new side of the
`1.2.043.42-itl-r10` recipe patch: the agent code-step route, the paired
file-code consumer `VAExtension_ITLОбработатьФайлКода`, and the main-form agent
helpers. A method is used only when it lies whole inside one patch hunk.

The doubles replace framework calls only:

- `vanessa-agent.os`: Vanessa step continuation, connection identity, logging
  and file commands. Storing a step variable fails, because the plain code step
  stores none.
- `server.os`: the shipped body of `ВыполнитьКодСервер` plus a record of its
  privilege flag.
- `addin.os`: the VanessaExt foreground window, its owner process and
  activations.
- The monitor start replaces only its TestClient UI actions (opening the monitor
  form, typing the directory and pressing its buttons). It keeps the production
  channel preparation `ITLПодготовитьКаталогКанала` and registration.

OneScript performs the actual `Выполнить`, JSON, filesystem I/O and exclusive
`CreateNew` claims. Paths contain Cyrillic and whitespace together.

`result-variable-unwrapped` reproduces why the route resets `Результат`: the
same code sent without the reset executes but leaves no reply.

This is executable evidence, not proof of an installed TestClient, the monitor
form UI or OS window focus. Native qualification of the paired build remains
required.

## r11 probes

The `r11-*.os` probes run production methods of the `1.2.043.42-itl-r11` recipe
for the PM5 defects of 06.11.2026:

- `r11-clipboard-route.os`: the clipboard code steps in agent, manual and
  channel-less launches, with the PM5 calibration exception and a compilation
  error; `vanessa-agent.os` signals the upstream clipboard entry by raising.
- `r11-feature-load.os` with `mcp-server.os`: run_scenario reload decision,
  SHA-256 of the loaded bytes, a file changed during the load, XML-invalid
  characters with their position and a missing file.
- `r11-row-settle.os` with `row-table.os`: the navigated row is read once per
  Vanessa sleep until it settles; the PM5 tree first shows the requested row and
  then the row its activation handler returned to.
- `r11-html-dom.os` with `dom-node.os`, `ui-field.os` and `ui-window.os`: the
  DOM search of the paired VAExtension form and its caller. The only adapted
  production text is the `ТестируемаяКнопкаФормы` type literal, which OneScript
  does not define.

They do not prove the TestClient DOM bridge, platform dialogs or window
matching; the native build and the Release E2E stage remain required.
