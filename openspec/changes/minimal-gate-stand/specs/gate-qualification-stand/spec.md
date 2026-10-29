# Spec Delta

## Purpose

Гейты Develop и Release квалифицируют workflow на воспроизводимом стенде из минимальной конфигурации репозитория, чтобы время выпуска определялось проверкой workflow, а не размером прикладной конфигурации.

## ADDED Requirements

### Requirement: Gate stand is built from a repository fixture
Стенд квалификации SHALL собираться одной командой из XML-фикстуры репозитория штатными путями workflow: создание файловой ИБ, configured init, Develop и Release worktree, negative и positive проекты, `release-e2e.json`. Сборка SHALL не требовать внешней ИБ или лицензируемой прикладной конфигурации.

#### Scenario: Building a stand on a new clone
- **WHEN** разработчик запускает сборщик с пустым каталогом, путь которого содержит пробел и кириллицу
- **THEN** получается стенд, на котором PublishDevelop проходит подготовку и Capture без ручных шагов

#### Scenario: Target directory is not empty
- **WHEN** каталог стенда уже содержит файлы
- **THEN** сборщик отказывает до любых изменений и предлагает указать новый каталог

### Requirement: Fixture keeps size-independent hazards
Фикстура SHALL содержать длинные кириллические имена объектов и форм, модули форм и объектов, общий модуль с серверным вызовом, макет с двоичными данными и роль, а также поддерживать расширения, Vanessa TestClient и YAxUnit. Негативный вариант SHALL отличаться одним изменением, дающим одну ожидаемую диагностику `/CheckConfig`.

#### Scenario: Production check rejects the negative variant
- **WHEN** upgrade journey выполняет production-проверку негативного варианта
- **THEN** `/CheckConfig` сообщает ожидаемую диагностику, конфигурация БД не применяется, а снимок и курсор восстанавливаются, как в существующем сценарии отказа

### Requirement: Gate assertions are unchanged
Переход на стенд из фикстуры SHALL не ослаблять утверждения сценариев Develop и этапов Release, их таймауты и бюджеты. Ожидания, зависящие от конфигурации, SHALL браться из конфигурации стенда, а не из кода.

#### Scenario: A PM5 property is hard-coded in a scenario
- **WHEN** при переходе сценарий ожидает свойство, существующее только в PM5
- **THEN** ожидание переносится в конфигурацию стенда, а утверждение сохраняет свою строгость

### Requirement: Proofs do not cross stands
Капсулы, journey- и stage-proofs SHALL быть привязаны к своему стенду. Первая квалификация на стенде из фикстуры SHALL выполняться холодно; proofs PM5-стенда SHALL не допускаться.

#### Scenario: First publication on the new stand
- **WHEN** PublishDevelop впервые запускается с новым `-E2EProjectRoot`
- **THEN** все выбранные сценарии выполняются заново, а proofs PM5 не используются для пропуска
