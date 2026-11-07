ПодключитьСценарий(КаталогФикстуры + "/vanessa-agent.os", "ТестоваяВанесса");
ПодключитьСценарий(КаталогФикстуры + "/mcp-server.os", "ТестовыйСерверMCP");
Ванесса = Новый ТестоваяВанесса;
СерверMCP = Новый ТестовыйСерверMCP;
Сценарий = АргументыКоманднойСтроки[0];
Путь = АргументыКоманднойСтроки[1];

Если Сценарий = "reload" Тогда
    ПутьВторойВерсии = АргументыКоманднойСтроки[2];
    Хеш1 = АргументыКоманднойСтроки[3];
    Хеш2 = АргументыКоманднойСтроки[4];
    // The first run_scenario call with filePath loads the file once and reports its bytes.
    Доп = Новый Структура("Тип,ПутьКФайлу,Режим", "ВыполнитьСценарий", Путь, "all");
    Проверить(ITLФайлФичиНадоЗагрузитьЗаново(Путь, Доп), "EXPLICIT_PATH_NOT_LOADED");
    Проверить(НЕ ITLФайлФичиНадоЗагрузитьЗаново("", Доп), "PATHLESS_RUN_RELOADED");
    // select_scenario and select_step chose a position in the loaded text; a reload would move it.
    Проверить(НЕ ITLФайлФичиНадоЗагрузитьЗаново(Путь, Новый Структура("Режим", "selected")), "SELECTED_RUN_RELOADED");
    Проверить(НЕ ITLФайлФичиНадоЗагрузитьЗаново(Путь, Новый Структура("Режим", "fromCurrentStep")), "CURRENT_STEP_RUN_RELOADED");
    Проверить(ITLФайлФичиНадоЗагрузитьЗаново(Путь, Новый Структура("Режим", "reloadAndRunFromLine")), "LINE_RUN_NOT_RELOADED");
    Проверить(ITLПодготовитьЗагрузкуФичи(Путь, Доп), "VALID_FEATURE_REJECTED");
    Проверить(Доп.ITLSha256Фичи = Хеш1, "SHA_CHANGED: " + Доп.ITLSha256Фичи);
    Проверить(НЕ ITLФайлФичиНадоЗагрузитьЗаново(Путь, Доп), "LOADED_CALL_RELOADS_AGAIN");
    Проверить(ITLФичаНеИзмениласьПриЗагрузке(Доп), "UNCHANGED_FEATURE_REJECTED");
    Строки = Новый Массив;
    ITLДобавитьХешФичиВРезультат(Строки, Доп);
    Результат = СтрСоединить(Строки, Символы.ПС);
    Проверить(СтрНайти(Результат, "featureFile: " + Путь) > 0 И СтрНайти(Результат, "featureSha256: " + Хеш1) > 0, "SHA_NOT_REPORTED: " + Результат);
    // PM5 reproducer: the file is edited and the same filePath is sent again with mode all.
    // The editor tab still holds this path, yet the second call loads the new bytes.
    КопироватьФайл(ПутьВторойВерсии, Путь);
    Доп2 = Новый Структура("Тип,ПутьКФайлу,Режим", "ВыполнитьСценарий", Путь, "all");
    Проверить(ITLФайлФичиНадоЗагрузитьЗаново(Путь, Доп2), "SAME_PATH_REUSED_STALE_TREE");
    Проверить(ITLПодготовитьЗагрузкуФичи(Путь, Доп2), "EDITED_FEATURE_REJECTED");
    Проверить(Доп2.ITLSha256Фичи = Хеш2, "EDITED_SHA_CHANGED: " + Доп2.ITLSha256Фичи);
    Проверить(СерверMCP.Ошибки.Количество() = 0, "VALID_LOAD_REJECTED");
ИначеЕсли Сценарий = "changed-during-load" Тогда
    ПутьВторойВерсии = АргументыКоманднойСтроки[2];
    Хеш1 = АргументыКоманднойСтроки[3];
    Хеш2 = АргументыКоманднойСтроки[4];
    Доп = Новый Структура;
    Проверить(ITLПодготовитьЗагрузкуФичи(Путь, Доп), "VALID_FEATURE_REJECTED");
    КопироватьФайл(ПутьВторойВерсии, Путь);
    Проверить(НЕ ITLФичаНеИзмениласьПриЗагрузке(Доп), "CHANGED_FEATURE_EXECUTED");
    Проверить(СерверMCP.Ошибки.Количество() = 1, "REJECTION_NOT_SENT_ONCE");
    Ошибка = СерверMCP.Ошибки[0];
    Проверить(Ошибка.id = "mcp-request-1" И Ошибка.code = "ITL_VANESSA_COMMAND_REJECTED", "REJECTION_CODE_CHANGED: " + Ошибка.code);
    Проверить(СтрНайти(Ошибка.text, "ITL_FEATURE_CHANGED_DURING_LOAD") > 0 И СтрНайти(Ошибка.text, Хеш1) > 0 И СтрНайти(Ошибка.text, Хеш2) > 0, "CHANGE_NOT_REPORTED: " + Ошибка.text);
    Проверить(Ванесса.ИдентификаторЗадачиMCP() = Неопределено И Ванесса.ФлагиОчищены = 2, "REQUEST_STATE_RETAINED");
ИначеЕсли Сценарий = "invalid-character" Тогда
    Ожидаемое = АргументыКоманднойСтроки[2];
    Доп = Новый Структура;
    Проверить(НЕ ITLПодготовитьЗагрузкуФичи(Путь, Доп), "INVALID_CHARACTER_ACCEPTED");
    Проверить(НЕ Доп.Свойство("ITLSha256Фичи"), "REJECTED_FEATURE_HASHED");
    Проверить(СерверMCP.Ошибки.Количество() = 1, "REJECTION_NOT_SENT_ONCE");
    Ошибка = СерверMCP.Ошибки[0];
    Проверить(Ошибка.code = "ITL_VANESSA_COMMAND_REJECTED", "REJECTION_CODE_CHANGED: " + Ошибка.code);
    Проверить(СтрНайти(Ошибка.text, "ITL_FEATURE_INVALID_XML_CHARACTER: " + Путь + ":" + Ожидаемое) > 0, "POSITION_NOT_REPORTED: " + Ошибка.text);
    Проверить(Ванесса.ИдентификаторЗадачиMCP() = Неопределено, "REQUEST_STATE_RETAINED");
ИначеЕсли Сценарий = "missing" Тогда
    // A missing file keeps the loader's own diagnostics and reports no hash.
    Доп = Новый Структура;
    Проверить(ITLПодготовитьЗагрузкуФичи(Путь, Доп), "MISSING_FILE_REJECTED_BEFORE_LOADER");
    Проверить(Доп.ITLSha256Фичи = "", "MISSING_FILE_HASHED");
    Строки = Новый Массив;
    ITLДобавитьХешФичиВРезультат(Строки, Доп);
    Проверить(Строки.Количество() = 0 И ITLФичаНеИзмениласьПриЗагрузке(Доп), "MISSING_FILE_REPORTED");
Иначе
    ВызватьИсключение "UNKNOWN_CASE: " + Сценарий;
КонецЕсли;
Сообщить("R11_CASE_PASSED: " + Сценарий);
