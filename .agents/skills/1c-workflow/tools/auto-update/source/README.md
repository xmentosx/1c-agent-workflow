# Main Enterprise auto-update EPF

`ItlAutoUpdateProof.xml` and its form files are the source of the bundled
`../ДляАвтоматическогоОбновленияИБ.epf`. Build the EPF with 1C Designer
`/LoadExternalDataProcessorOrReportFromFiles` against a disposable infobase,
using the workflow `Invoke-Designer` helper so the per-infobase guard owns the
launch. The bundled binary was built with platform 8.3.27.2130. Keep source and
binary in the same change and verify that unpacking the binary yields the same
form module.

The helper passes a UTF-8 JSON parameter file through one `/C<path>` argument with `runId`,
`outputPath`, and, for development branch normalization, `applicationTitle`. The EPF writes
schema 2 JSON to `outputPath`, including the same `runId`, `status`, `updateResult`,
`errorMessage`, `errorDetails`, `titleStatus`, `titleValue`, and `titleError`. Only
`status=passed` with update result `Успешно` or `НеТребуется` is success.

After a successful update the EPF stores `applicationTitle` in the standard БСП constant
`ЗаголовокСистемы`: it reads first, writes only on difference, and verifies by reading back.
`titleStatus` is `set`, `unchanged`, `skipped` (no such constant), `failed` (with
`titleError`), `not-requested`, or `not-run` when the update itself failed. A title failure never
changes `status`.
