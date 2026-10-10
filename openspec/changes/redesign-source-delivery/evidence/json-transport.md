# Proof JSON: причина и проверка исправления

База исследования: fa0e3c91694112c1da3ecda7209a8a81ea828264.
Владельцы: stateless source-proof-json и существующий delivery hot-index.
Shared runtime authority и формат schemaVersion=1 не расширены.

## Две независимые причины

Core автоматически превращал ISO dates в DateTime; точность и offset исходной
строки переставали быть данными payload. Сохранение строк восстановило hash
в Core, но само по себе не исправило чтение Windows PowerShell.

На семантически одинаковых payload с одинаковым порядком полей обнаружена вторая
причина: serializer 5.1 заменяет четыре символа ' < > & на JSON Unicode escapes.
Core по умолчанию сохраняет их буквально. Core EscapeHtml не является заменой:
он дополнительно заменяет кавычки на u0022 и снова даёт другие байты.

Контроль неизменённого исторического индекса:

| Представление payload | SHA256 |
|---|---|
| Core, даты сохранены строками; совпал с записанным SHA | 9e092ffe95bff189ef03c2868d1f8a7f9dc0cb630fba0965113b340154768e48 |
| Windows PowerShell 5.1, те же строки | 5336b492fc1fe7be2315c861d2abbaae1f93633f5d79f362c098255dfdacdf6b |
| Core EscapeHtml | ca3b3d60d9764d6de9b7defae346f26f2c2842b89b6e2fd053329b6caba50bc6 |

Сравнение разобранных представлений не выявило отличий значений, типов и порядка.
Замена только четырёх литеральных символов дала точное совпадение bytes с 5.1.
Обратное преобразование настоящих escapes (с сохранением literal backslash text)
дало точное совпадение с legacy Core bytes. Источник не переписывался.

DateKind введён в PowerShell 7.5:
[официальная документация](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/convertfrom-json?view=powershell-7.5).
Для более раннего Core использован уже загруженный Json.NET reader с
DateParseHandling=None; отдельная библиотека или установка не требуется.

## Исправление и границы

Новые hot-index записи используют установившееся escaping 5.1. Reader сохраняет
даты строками и проверяет canonical SHA либо конкретный исторический Core SHA.
Это два детерминированных представления одного payload, а не игнорирование SHA.
Неизвестная схема, изменение значения, неверный source directory, pending writers
и stale source stamp сохраняют существующие результаты отказа.

Изменены только доказанные consumer boundaries hot-index: raw records при
перестроении, сам индекс и pending marker reader. Остальные JSON-владельцы
не объявляются автоматически исправленными. Реальный процесс writer, 10000 raw
records, concurrent writers и проверки authoritative raw proof сохранены.

## Focused acceptance, 2026-10-11

| Проверка | Core 7.6.5 | Windows PowerShell 5.1.26100.9549 |
|---|---:|---:|
| SourceProofJson | 6 passed | 5 passed, 1 Core-only skip |
| SourceDeliveryRunIndex, полный файл | 14 passed, 36.43 s | 14 passed, 42.80 s |

Новый immutable legacy fixture имеет независимо рассчитанный SHA
e4d3a3ddd332a40633dd5698ff6f723f37c9c96bcf4bdc585bf8a0813dffad54.
Оба runtime читают его, сохраняют dates/offset/int64/Unicode; reader не изменяет
bytes. После записи canonical proof читается снова; подмена message отвергается.

Read-only probe настоящего общего индекса: status=ready, validRunCount=1653 в
обоих runtime. Byte SHA до и после:
5f69ee083c67cb593a90f15990cb00e5f0ff5506e2cd521874ac10048180815b.
Использован [probe-run-index-read.ps1](probe-run-index-read.ps1).
Полные JUnit/results находятся в ignored build/redesign-source-delivery.
Это focused acceptance реализации; регистрация, общая квалификация и публикация
данного change ещё не выполнены.
