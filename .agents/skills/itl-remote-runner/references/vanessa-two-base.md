# Remote Vanessa with a service manager base and a target TestClient base

Use this recipe when Vanessa TestManager must run in a service file base while
the product scenario runs in a different TestClient base. Declare both exact
resources before packing the job. The primary `infoBase` is always included in
the execution guard; including it again in `additionalBases` is harmless and
makes the two-base intent visible in the target profile.

```json
{
  "infoBase": {"kind": "server", "path": "server\\project_test"},
  "execution": {
    "host": "interactive-worker",
    "additionalBases": [
      {"kind": "file", "path": "C:\\ITL\\vanessa service"},
      {"kind": "server", "path": "server\\project_test"}
    ]
  },
  "vanessa": {
    "managerBase": {"kind": "file", "path": "C:\\ITL\\vanessa service"},
    "epf": "C:\\ITL\\VanessaAutomation.epf",
    "settingsTemplate": "C:\\ITL\\private\\VAParams-template.json"
  }
}
```

The target also needs the normal `workspace`, `platform`, `allowedOperations`
and other fields required by the job contract. `Invoke-OneCProcess.ps1` launches
role `manager` against `vanessa.managerBase`; TestClient remains bound to the
named Vanessa profile and must use `target.infoBase`. Do not point TestManager
at the product base to work around a profile error.

In the pinned Vanessa settings, give the TestClient profile a stable name,
`ПутьКИнфобазе` for the exact target base and a `ПортЗапускаТестКлиента` inside
`ДиапазонПортовTestclient`. Prefer a bounded range when a single port is
rejected by Vanessa; that error does not prove the port is occupied by the OS.
The adapter writes `vanessa-preflight.json` with the effective range, profile
names and ports, and whether each configured port is inside the range. A
`single-port-range-configured` diagnosis calls for inspection of Vanessa's
profile and port selection. It is diagnostic, not a reason to bypass the guard
or declare an OS conflict.

Start the feature with an explicit profile, then assert the actual connection
from inside the owned TestClient before any product action:

```gherkin
Сценарий: Работа в целевой базе
    Дано Я подключаю профиль TestClient "project_ui"
    И TestClient подтверждает фактическую базу "server\project_test"
    Когда я выполняю продуктовый шаг
```

The second step is a project-owned assertion: implement it against the current
TestClient connection in that project's feature adapter and make a mismatch
fail as `wrong-target`. A profile declaration alone and a passed JUnit do not
prove the loaded base. As a second observation, retain Vanessa's line
`Подключен клиент тестирования ... Строка соединения </S server\project_test>`
in `vanessa.log`. `manager-result.json` records the actual manager launch base,
PID, start/end times, exit-code availability, fresh status and JUnit counts.
The target role is confirmed only when the in-client assertion or equivalent
runtime evidence accompanies the log. Preserve both role observations in the
collected result; do not infer target identity from TestManager's base.

Run `remote --action status` and `remote --action collect --allow-partial` while
the job is active. After completion, collect the final result and inspect
`vanessa-preflight.json`, `manager-result.json`, `vanessa.log` and the feature's
target assertion. A generated screenshot is a file artifact; open it to verify
that the TestClient content is visible before citing it as visual evidence.
Black or otherwise unusable captures do not invalidate a successful business
scenario unless visible UI evidence was an explicit acceptance requirement.
