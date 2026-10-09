# Откат основного Mac

Текущий app: `build/Parrot-improved-2026-10-09.app`. Прежний Ultra: `recordings/backups/2026-10-09-improvement/Parrot-Ultra-rollback.app`, SHA256 main `7a5be67795849ef393827dc347f6e0631de042e7f4d2a58304d2221e0f1bcec3`.

1. Проверить отсутствие записи и выйти через меню Parrot. Не заменять работающий bundle.
2. Сохранить текущий app. Через Finder скопировать rollback app в `/Applications`, назвать `Parrot.app`, проверить подпись, открыть из Finder.
3. Модели refinement сохранить: прежний Ultra их не использует. Защита памяти Qwen 9B остаётся прежней.

Приватная исходная DB: `recordings/backups/2026-10-09-improvement/database/`, три файла `default.store`, `default.store-wal`, `default.store-shm`; quick_check OK, 88 встреч. [Хеши](evidence/backup-result.json).

Базу восстанавливать только при несовместимости схемы. Сначала сохранить текущие DB/WAL/SHM и аудио через Finder: в старой копии нет шести QA и последующих встреч. Sandbox-каталог: `~/Library/Containers/com.uygar.parrot/Data/Library/Application Support/`. Аудио не переносилось и не удалялось. Простому откату app предварительная замена истории не нужна.

Второй Mac не менялся; его rollback пути — в историческом отчёте Ultra.
