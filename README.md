# Methamphetamine

Нативное macOS menu bar-приложение без Dock-иконки. Оно находит локальные кодинговые агенты и не даёт Mac автоматически уснуть, пока запущен хотя бы один из них.

## Продуктовый контракт

Основной переключатель означает: **не давать Mac уснуть, пока запущен хотя бы один поддерживаемый агент**.

- при включённом переключателе учитываются все поддерживаемые агенты без отдельной настройки каждого;
- завершение внутренней задачи не снимает защиту, если приложение или CLI агента остаётся открытым;
- после завершения последнего процесса защита снимается сразу;
- ручное выключение переключателя снимает защиту сразу;
- новые поддерживаемые агенты учитываются автоматически;
- состояние переключателя сохраняется между запусками.

Переключатель **«Экономить заряд»** включён по умолчанию. Когда Mac работает от батареи и заряд опускается ниже 10%, приложение временно снимает защиту от сна. При 10% и выше или после подключения питания защита возобновляется, если агент всё ещё запущен. Если состояние батареи прочитать не удалось, основной режим продолжает работать.

Список найденных агентов в меню не показывается. Никакого подключения к аккаунтам или API агентов нет.

## Поддерживаемые агенты

| Агент | macOS-приложение | CLI |
| --- | --- | --- |
| [Codex](https://github.com/openai/codex) | `com.openai.codex` | `codex` |
| [Claude Code](https://code.claude.com/docs/en/quickstart) | `com.anthropic.claudefordesktop` | `claude` |
| [Cursor](https://docs.cursor.com/en/cli/installation) | `com.todesktop.230313mzl4w4u92` | `cursor-agent` |
| [Devin](https://docs.devin.ai/) (бывший Windsurf) | `com.exafunction.windsurf` | `devin` |
| [Zed Agent](https://zed.dev/docs/ai/overview) | `dev.zed.Zed` | — |
| [OpenCode](https://opencode.ai/docs/cli/) | `ai.opencode.desktop` (+ Beta/Dev) | `opencode` |
| [Gemini CLI](https://github.com/google-gemini/gemini-cli) | — | `gemini` |
| [GitHub Copilot CLI](https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/install-copilot-cli) | — | `copilot`† |
| [Aider](https://aider.chat/docs/install.html) | — | `aider` |
| [Kimi Code](https://www.kimi.com/code/docs/en/) | — | `kimi` |
| [Qwen Code](https://github.com/QwenLM/qwen-code) | `com.alibaba.qwen-code` | `qwen` |
| [Grok Build](https://docs.x.ai/build/cli/reference) | — | `grok`† |
| [Kiro](https://kiro.dev/docs/cli/installation/) | `dev.kiro.desktop` | `kiro-cli` |
| [Google Antigravity](https://antigravity.google/docs/cli/getting-started) | `com.google.antigravity`, `com.google.antigravity-ide` | `agy` |
| [Amp](https://ampcode.com/manual) | — | `amp`† |
| [Auggie](https://docs.augmentcode.com/cli/overview) | — | `auggie` |
| [Cline CLI](https://docs.cline.bot/cli/cli-reference) | — | `cline` |
| [Continue CLI](https://docs.continue.dev/cli/quickstart) | — | `cn`† |
| [Factory Droid](https://docs.factory.ai/cli/getting-started/quickstart) | — | `droid`† |
| [Goose](https://github.com/block/goose) | `com.block.goose`, `com.electron.goose` | `goose`† |
| [Mistral Vibe](https://github.com/mistralai/mistral-vibe) | — | `vibe`, `vibe-acp`† |
| [Junie CLI](https://junie.jetbrains.com/docs/junie-cli.html) | — | `junie` |
| [Kilo Code](https://kilo.ai/docs/code-with-ai/platforms/cli) | — | `kilo`† |
| [Crush](https://github.com/charmbracelet/crush) | — | `crush`† |
| [OpenHands CLI](https://docs.openhands.dev/openhands/usage/cli/installation) | — | `openhands` |
| [CodeBuddy Code](https://www.codebuddy.cn/docs/cli/installation) | — | `codebuddy` |
| [Codebuff](https://www.codebuff.com/docs/help/quick-start) | — | `codebuff` |
| [Tabnine CLI](https://docs.tabnine.com/main/getting-started/tabnine-cli) | — | `tabnine` |
| [Neovate Code](https://github.com/neovateai/neovate-code) | — | `neovate` |
| [Pochi](https://docs.getpochi.com/cli/) | — | `pochi` |
| [Qoder CLI](https://docs.qoder.com/en/cli/quick-start) | — | `qodercli` |
| [Trae Agent](https://github.com/bytedance/trae-agent) | `com.trae.app` | `trae-cli` |
| [Pi Coding Agent](https://github.com/earendil-works/pi/tree/main/packages/coding-agent) | — | `pi`† |
| [Warp Oz](https://docs.warp.dev/reference/cli) | — | `oz`, `oz-preview`† |

† У команды неоднозначное имя, поэтому совпадения по одному basename недостаточно: дополнительно проверяется реальный путь установки, подпись разработчика или служебный каталог продукта.

В основной список намеренно не входят модели без собственного локального клиента, браузерные агенты, IDE-плагины без отдельного процесса, закрытые и устаревающие продукты вроде Roo Code, iFlow CLI или Qodo Gen CLI, а также инфраструктурные конструкторы агентов вроде Docker Agent. Их нельзя честно связать с локально выполняющейся задачей тем способом, который использует приложение.

Произвольный неизвестный агент автоматически распознать нельзя: для него нужно добавить стабильные сигнатуры в `CodingAgentCatalog`.

## Как работает обнаружение

- приложения находятся по bundle ID через `NSWorkspace`; URL из Launch Services дополнительно проверяется на диске;
- CLI ищутся по точному имени в официальных каталогах самих агентов и в глобальных каталогах Homebrew, local, Cargo, Bun, Volta, pnpm, nvm, asdf и mise;
- для коротких или общеупотребительных CLI-имён проверяется канонический target symlink, подпись разработчика либо наличие служебного каталога конкретного агента;
- процессы CLI учитываются только для текущего пользователя и только с controlling TTY;
- native-бинарники и Node/Python-launcher сопоставляются с реальным путём найденной установки, а не только по имени процесса;
- внутренние `*.app/Contents/Resources`, проектные `node_modules/.bin` и `codex app-server` не считаются отдельными агентами;
- бинарники не запускаются с `--version`; чаты, транскрипты и конфигурация агентов при обычном обнаружении не читаются. Из списка процессов разбираются только путь запуска и первые аргументы, нужные для распознавания launcher/helper; они не сохраняются.

Установка через нестандартный каталог или запуск вида `python -m aider` могут не обнаружиться в текущей версии.

Для Cursor, Devin, Zed, Kiro и других desktop-продуктов запущенным считается открытое приложение. Methamphetamine не видит, выполняется ли прямо сейчас внутренняя задача агента, поэтому защита может оставаться активной, пока открыт редактор.

## Разрешения и сон

Для обычного автоматического сна приложение использует публичный IOPM idle-sleep assertion. Чтобы агенты продолжали работать и после закрытия крышки, оно также переключает системный режим Power Protect теми же двумя командами, что использует Amphetamine:

```bash
sudo pmset -a disablesleep 1
sudo pmset -a disablesleep 0
```

При первом включении macOS один раз попросит Touch ID или пароль администратора. Установленное правило разрешает текущему macOS-пользователю без повторных запросов выполнять только эти две точные команды. Оно не даёт приложению произвольный root-доступ.

Приложению по-прежнему не нужны:

- Automation или Apple Events;
- Accessibility;
- Full Disk Access;
- Amphetamine;
- hooks Codex или Claude.

Methamphetamine запоминает, меняло ли оно системный режим само. Если `SleepDisabled` уже был включён другой программой, приложение не выключает его за неё. Если режим включила Methamphetamine, она возвращает обычный сон сразу после завершения последнего агента, при выключении переключателя и при штатном завершении приложения. Локальный watchdog также пытается вернуть сон после аварийного завершения, а незакрытая сессия восстанавливается при следующем запуске.

Закрытие крышки всё равно может заблокировать экран — критерий успеха в том, что процессы агентов продолжают работать. Состояние батареи читается через публичный IOKit API и не требует отдельного разрешения. Поведение недокументированного `disablesleep` при ручной команде Sleep, критическом заряде, перегреве, системном сбое и жёсткой перезагрузке не гарантируется. Закрытый Mac может быстрее разряжаться и сильнее нагреваться; не кладите его работающим в сумку.

`pmset disablesleep` — глобальная системная настройка без владельца и reference counting. Одновременное использование Amphetamine, ручного `pmset` и Methamphetamine может привести к конфликту. В этой локальной сборке применяется отдельное для текущего UID узкое правило `sudoers`, подходящее для прототипа; удаление приложения само это правило не удаляет. Для публичного распространения его нужно заменить подписанным и нотарифицированным привилегированным helper с lease/heartbeat через `SMAppService`.

## Миграция со старой версии

При обновлении прежний выбор агентов переносится в общий переключатель: если был включён хотя бы один агент, защита остаётся включённой. Версия 0.2 также один раз читает прежние hook-настройки и удаляет только команды старого `Contents/Helpers/meth-hook` с маркером `methamphetamine-hook`. Перед изменением рядом с реальным JSON-файлом создаётся timestamped backup. Остальные настройки и hooks сохраняются.

## Сборка

Требуются macOS 13+ и Swift 6 toolchain.

```bash
swift test
swift build -c release
./scripts/package.sh
```

Готовый bundle для архитектуры текущего Mac создаётся в `dist/Methamphetamine.app`. Локальный скрипт использует ad-hoc подпись. Для распространения клиентам нужны Universal 2 либо отдельные сборки, Developer ID подпись и notarization.

## Проверка

Тесты покрывают каталог сигнатур, точное сопоставление app и CLI, Node/Python-launcher, дедупликацию, исключение helpers и процессов без TTY, оба переключателя, порог заряда и питание от сети, миграцию прежнего выбора, немедленное снятие защиты, Power Protect без реального `sudo` и read-only smoke scan реальной системы.
