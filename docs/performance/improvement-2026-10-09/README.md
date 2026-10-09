# Parrot — основной Mac, выпуск 2026-10-09

Установлено на MacBook Pro M5 Pro, 64 ГБ, с прежней подписью и разрешениями. Второй Mac не менялся. [Продолжение](STATE.md) · [откат](ROLLBACK.md) · [исходный аудит](../audit-2026-10-09/README.md) · [сборка](../../BUILD.md) · [Git-передача 2026-10-10](../../GIT-HANDOFF.md).

## Изменения

- Stop и выход публикуют состояние на MainActor, закрывают аудио и откладывают завершение до сохранения. Исправлен также реальный deadlock нового worker: чтение короткого ответа ожидало заполнения 64 КБ. Nonblocking pipe теперь читает доступные байты и допускает отмену.
- Новая запись прерывает фоновые задачи и освобождает worker. Завершённые окна сохраняются для продолжения.
- Whisper обрабатывает до четырёх окон. Автоматическая Final-версия использует Whisper для обычных окон и Qwen3-ASR при независимо обнаруженной смене языков; эталоны и ID тестов не участвуют в routing.
- Аудио и Live-текст сохраняются. Есть выбор Final / Live и честная пометка приблизительных позиций. Hybrid-идентичность отражена в артефактах и экспорте. Старую историю автоматически не перерабатывает.

## Проверки

[Подпись](evidence/release-final-signature.json): main `c1c3aacfb66bae5768f6593d5ca466a0a0d7ce43712e2b433422f17c96746302`, Team `5C2PL8729F`, исходные entitlement сохранены. [Установка](evidence/install-result.json).

- [258 тестов](evidence/release-full-tests-pipe-repair.log), ноль ошибок; включая настоящий открытый pipe, отмену читателя и выход именно его child process.
- [Production capture](evidence/release-production-capture.log): system 184960 / mic 180560 кадров, оба сигнала ненулевые; echo alignment 1123, 5 passthrough, ноль ошибок конвертации.
- [Offline speech](evidence/offline-result.json): signed-копия без обоих network entitlement завершила mixed-фрагмент с одной ошибкой, worker вышел. Сеть macOS не отключалась.
- [GUI](evidence/gui-workflow-result.json): Stop/Save, Final/Live, воспроизведение с движением позиции, Stop → немедленный Quit, обычный меню Quit во время записи, новая запись при Preparing final transcript. В последнем случае активный захват наблюдался через 6.385 с; это включает задержку UI-автоматизации.
- Все шесть собственных QA-встреч явно названы Parrot QA и имеют аудио, Live и автоматический hybrid Final. Физический Quit в отдельном статусном popover не проверен: CUA исключает статусную панель. Регрессия проверяет close → возврат обработчика → deferred terminate.

[Сохранность](evidence/history-preservation-result.json): все исходные 88 ID, данные встреч и 21647 Live-сегментов, включая текст, время и говорящего, совпадают по каноническим SHA256. Добавлены шесть QA-встреч. Личная комнатная речь и записи QA остаются приватными; публичные документы содержат агрегаты.

## Качество и скорость

[Объявленные критерии](../../../Tools/qa/quality-corpus.json) · [gate на точном установленном c1](evidence/quality-gate-installed-result.json). Десять TTS-фрагментов, 473 слова; все завершены, timestamp/worker-exit проверки пройдены.

| Язык | Ошибки Whisper | Ошибки hybrid |
|---|---:|---:|
| RU, 133 слова | 2 | 2 |
| PL, 128 слов | 0 | 0 |
| EN, 169 слов | 0 | 0 |
| Смена RU/PL/EN, 43 слова | 12 | 1 |
| Всего | 14 | 3 |

Прямые Qwen/MOSS кандидаты отклонены: ухудшали отдельные языки.

[EN-контроль](evidence/en-benchmark/summary.json), 60.462 с: последовательные workers 1/4/4/1; медианы 5.951 / 5.357 с, около 11.1% ускорения. Текст и полные content-хеши одинаковы. Hybrid: 9.565 с, ноль ошибок против одной у Whisper.

[Длинная смена языков](evidence/long-benchmark/summary.json), 216.786 с: hybrid 23/473 ошибок, 60.622 с обработки. Whisper давал нестабильные 64/133 ошибки при workers1 и 110/142 при workers4; этот случай не принят как batch-equivalence доказательство. Переключения на границах 30-секундных окон остаются сложным случаем.

Первый исправленный signed hybrid прогон занял 68.368 с, включая загрузку/начальную специализацию, при параллельной компиляции и прогреве Whisper. Это не изолированный замер загрузки Qwen. Точный установленный повтор всех десяти занял 43.730 с суммарно после прогрева. Hybrid улучшил эти синтетические контроли и требует больше времени после встречи; они не доказывают качество на всех реальных разговорах или субъективное качество микрофона.

ASR guard — 6 GiB после наблюдавшегося MLX peak 3.68 GB. Прежний guard 10 GiB для Qwen 3.5 9B не ослаблялся.

## Файлы

- [Последний signed app](../../../build/Parrot-improved-2026-10-09.app); установлен в `/Applications/Parrot.app`.
- Локальные [исходный снимок](evidence/source-snapshot.tar.gz) и [патч](evidence/source-working-tree.patch); [manifest](evidence/source-snapshot-manifest.json), [seal](evidence/release-seal.json) и [индекс доказательств](evidence/README.md) хранятся в Git. Снимок включает сохранённые исходные изменения; pre-task patch оставлен отдельно. Архив и patches исключены из Git и доступны в исходной рабочей папке.
- [Приватный rollback app + DB/WAL](../../../recordings/backups/2026-10-09-improvement/); [приватный QA-манифест](../../../recordings/quality-2026-10-09/qa-meeting-manifest-labeled.json). Не публиковать и не отправлять эти папки.
- Helper: [инструкции/pins](../../../Tools/ASRWorker/README.md); portable output нужен `project.yml`. Новый clone сначала собирает worker, затем main по [BUILD](../../BUILD.md).
- [Cleanup](evidence/cleanup-result.json): входные копии и DerivedData удалены; исходная история, модельные кэши, Xcode и чужие приложения сохранены.
