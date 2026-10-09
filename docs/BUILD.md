# Сборка и проверка личной версии

Текущее принятое состояние и результаты: [выпуск 2026-10-09](performance/improvement-2026-10-09/README.md). Эти инструкции описывают подготовку новой сборки; изменение документации 2026-10-10 не заменяло установленное приложение.

## Подготовка

- Apple Silicon; macOS deployment target 14+. Проверенная среда: Xcode 27, Swift 6.4, XcodeGen и официальный Metal Toolchain.
- project.yml — источник Xcode-проекта; версии WhisperKit / FluidAudio должны совпадать с Package.swift и сохранённым resolved graph.
- Перед сборкой проверить свободный диск и текущие процессы согласно [AGENTS](../AGENTS.md) и родительским правилам. Каталоги сборки принадлежат задаче, имеют срок выполнения и удаляются после проверки; последние app и rollback сохраняются.
- Для установки на основном Mac сохранить прежнюю signing identity и entitlements. Не заменять работающее приложение с активной записью.

## Worker, затем основное приложение

Сначала собрать независимый MLX worker. Он использует собственный [Package.resolved](../Tools/ASRWorker/Package.resolved), не меняя граф зависимостей основного приложения:

```bash
python3 Tools/ASRWorker/build.py
xcodegen generate
python3 Tools/qa/run_bounded_job.py \
  --name parrot-release-build \
  --log build/release-build.log \
  --resource build/release-build-resource.json \
  --timeout 1200 -- \
  xcodebuild -project Parrot.xcodeproj -scheme Parrot \
    -configuration Release -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath build/DerivedData -disableAutomaticPackageResolution
```

Нужен настроенный сертификат прежней Apple Development команды. Post-build script проверяет checksum [llama runtime](../Vendor/QwenRuntime/README.md), переносит portable ASR worker и Metal-ресурсы в стандартный nested app, подписывает оба helper. Переопределения исходных путей: LLAMA_SERVER_SOURCE и ASR_WORKER_SOURCE. Готовый app: build/DerivedData/Build/Products/Release/Parrot.app.

После сборки выполнить codesign --verify --deep --strict, сравнить исходные entitlement и signing identity. Перед переносом в /Applications завершить запись, корректно выйти и сохранить текущие app, DB/WAL/SHM и аудио. Подробности и безопасное восстановление — в [ROLLBACK](performance/improvement-2026-10-09/ROLLBACK.md). Локальные модельные кэши и историю между Mac не подменять.

## Модели

Live использует Ultra + Silero и готовый Whisper fallback. Settings → Download / Reload Local Models загружает недостающие файлы. При ограничениях доступа к контейнеру использовать подписанный Parrot или Finder; не обходить их бесконечными shell-повторами.

Final native registry: [FinalSpeechModels.json](../Parrot/Resources/FinalSpeechModels.json). Он фиксирует revision, размер, SHA256 весов и обязательные файлы. Production selection хранится внутри Application Support/Parrot/FinalSpeech вместе с hash принятого quality gate. На основном Mac выбрана Qwen3-ASR 1.7B 8-bit; MOSS проверена, но не выбрана. Без подходящей selection приложение сохраняет Whisper Final.

Для новой установки сначала скачать и проверить pinned файлы, прогнать одинаковый объявленный корпус против Whisper и получить no-regression результат. Только затем подписанный app принимает локальную модель через --promote-final-model qwen SOURCE_ROOT EVIDENCE_SHA256. Смена selection действует при следующем запуске. Не использовать синтетические результаты как доказательство качества всех реальных созвонов. [Модельное решение](performance/improvement-2026-10-09/model-review.md), [QA-инструменты](../Tools/qa/README.md).

## Проверки перед установкой

Unit suite не требует модели или записи в пользовательскую историю:

```bash
python3 Tools/qa/run_bounded_job.py \
  --name parrot-unit-tests \
  --log build/unit-tests.log \
  --resource build/unit-tests-resource.json \
  --timeout 1200 -- swift test
```

Для изменения speech/capture путей нужны дополнительно bounded diagnostic runs из отдельной подписанной тестовой копии с той же identity. Сам CLI-тест не подтверждает GUI-поведение.

| Флаг исполняемого Parrot | Что проверяет |
|---|---|
| --capture-test | Production system/mic capture, метрики; диагностические файлы удаляются |
| --parakeet-test AUDIO | Live recognizer |
| --whisper-fallback-test AUDIO | Готовая локальная модель без повторного скачивания |
| --call-pipeline-test AUDIO | VAD / utterance path |
| --best-transcription-test AUDIO WORKERS EXPORT | Пакетный Whisper и контроль результатов |
| --final-transcription-test AUDIO ENGINE MODEL_ROOT WORKERS | Изолированный Final-проход; engines whisper/qwen/moss/hybrid |

Последний режим обычно выводит метрики и fingerprints. --print-fixture-transcript разрешён для явно синтетических данных; личную речь в публичные логи не выводить.

GUI acceptance после установки: Stop/Save, Final/Live, playback, Stop → немедленный Cmd-Q, Quit во время записи, новая запись при фоновой Final-обработке. Проверить исходную историю по данным и canonical hashes. Для локального inference использовать отдельную тестовую копию без обоих network entitlement; сеть macOS не менять. Статусный popover требует отдельного физического runtime-подтверждения, если UI-инструмент до него не добирается.

После принятия закрыть точные процессы задачи, проверить их выход и удалить принадлежащие задаче DerivedData/модельные сравнения. Рабочее приложение и данные пользователя сохранить. [Последний release seal](performance/improvement-2026-10-09/evidence/release-seal.json) фиксирует прежний проверенный выпуск; новый исходный код требует нового доказательства, а не перезаписи старого seal.
