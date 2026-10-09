# Передача в Git — 2026-10-10

Пользователь запросил обновление документации и сохранение работы в Git после принятого выпуска на основном Mac. Текущая ветка — codex/parakeet-call-engine, upstream — fork/codex/parakeet-call-engine в [Raw3hape/Parrot](https://github.com/Raw3hape/Parrot). Исходная точка проверенного выпуска — 5193b3543ecdfbe5d478fbb1687155466eb76e53.

В передачу входят интегрированные изменения Ultra/Whisper, надёжности захвата и фоновых задач, native worker, hybrid Final, тесты, pinned зависимости, документация и результаты проверок. Сохранённая работа Best Transcript включена в принятый выпуск. Перед обновлением документации 139 файлов приложения, тестов и конфигурации сверены с исходным sealed manifest; расхождений нет. Новый docs-проход не меняет исполняемый код или установленный app.

## Точки входа

- [README](../README.md) — актуальные возможности личной сборки.
- [BUILD](BUILD.md) — worker, подписанная сборка, модели, bounded диагностика и установка.
- [Release STATE](performance/improvement-2026-10-09/STATE.md) — результат и ограничения.
- [Release evidence](performance/improvement-2026-10-09/evidence/README.md) — проверочные результаты и локальные артефакты.
- [Проверка документации и состава Git](performance/improvement-2026-10-09/evidence/documentation-git-validation.json) — ссылки, синтаксис команд, JSON, source hashes и исключение приватных данных.
- [ROLLBACK](performance/improvement-2026-10-09/ROLLBACK.md) — сохранение текущих данных перед восстановлением.

release-seal.json и source-snapshot-manifest.json фиксируют состояние до этого Git-прохода. no_commit_or_push=true в историческом seal относится к моменту завершения проверки приложения; seal не перезаписывается последующим коммитом. Hash Git-коммита определяется через git log; main/helper hashes описывают подписанные бинарники и не равны commit hash.

## Локальные данные

Записи, восстановление Finalizing, базы, QA-речь и rollback остаются в исключённых из Git папках recordings. Точные pre-task/source patches, source-snapshot.tar.gz, большие build/debug logs и Python bytecode также остаются локально. Их оригиналы сохранены; исключение из Git не означает удаление.

Новый clone содержит исходники и результаты принятия, но не установленные модели или portable worker. Worker воспроизводится по BUILD и pinned graph. Для переноса на другой Mac нужны отдельная подготовка моделей и runtime-проверка; этот Git-проход не обновляет второй Mac.
