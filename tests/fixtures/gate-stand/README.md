# Gate stand fixture

Minimal configuration for the Develop and Release qualification stand built by
`scripts/new-gate-stand.ps1` (`openspec/changes/minimal-gate-stand`). It contains
no product objects; its contents cover size-independent hazards only: long
Cyrillic object and form names, form and object modules, a server-call common
module, a binary template and the role bound to the
`assets/vanessa-service/service-infobase.dt` user. Two server modules stand in
for the standard-subsystems entry points that the bundled Enterprise
auto-update EPF calls (`ОбновлениеИнформационнойБазы.ВыполнитьОбновлениеИнформационнойБазы`
and `ОбновлениеИнформационнойБазыСлужебный.ЗаписатьПодтверждениеЛегальностиПолученияОбновлений`);
the stand has no update handlers, so the update is never required.

`cf/` is a native Designer 8.3.27.2130 dump (format 2.20) and keeps its BOM/CRLF
bytes. The configuration is on vendor support (`ITL` 1.0.0.1) with vendor-object
editing enabled, so `Ext/ParentConfigurations.bin` exercises support-state
preservation. It was produced once: XML loaded into the service template base,
`/CreateDistributionFiles`, `/LoadCfg` of that distribution into a new template
base, a dump, the support header flag `{6,1,1,` changed to `{6,0,1,` (Designer's
"editing enabled"), a reload and a final dump. Designer then accepts partial
loads and round-trips the file byte for byte.

`negative/Module.bsl` replaces the form module named in `manifest.json`, leaving
the assigned `ПриСозданииНаСервере` handler without a procedure; production
`/CheckConfig` reports exactly the manifest diagnostic. `release/` holds the
Release-branch marker function and its Vanessa scenario.

To change the configuration, edit `cf/`, build a stand and keep `/CheckConfig`
clean for the positive variant.
