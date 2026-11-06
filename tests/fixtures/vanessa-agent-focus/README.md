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
