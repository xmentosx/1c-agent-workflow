# Main Enterprise auto-update EPF

`ItlAutoUpdateProof.xml` and its form files are the source of the bundled
`../ДляАвтоматическогоОбновленияИБ.epf`. Build the EPF with 1C Designer
`/LoadExternalDataProcessorOrReportFromFiles` against a disposable infobase,
using the workflow `Invoke-Designer` helper so the per-infobase guard owns the
launch. The bundled binary was built with platform 8.3.27.2074. Keep source and
binary in the same change and verify that unpacking the binary yields the same
form module.

The helper passes a UTF-8 JSON parameter file through `/C` with `runId` and
`outputPath`. The EPF writes schema 1 JSON to `outputPath`, including the same
`runId`, `status`, `updateResult`, `errorMessage`, and `errorDetails`. Only
`status=passed` with update result `Успешно` or `НеТребуется` is success.
