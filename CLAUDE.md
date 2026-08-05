# Qyvro

Файловый менеджер для macOS для работы с большими объёмами изображений и видео:
генеративная графика, монтаж, дизайн. Личный проект, распространяется как
самоподписанный `.app`.

**Папка называется `FPilotMac`, продукт называется Qyvro.** Это историческое
имя, папку не переименовывать: на него завязаны `build_app.sh`, каталог бэкапов
`../FPilotMac_Backups` и правила в `.claude/settings.json`. В коде и в интерфейсе
всегда «Qyvro».

- Bundle id `com.qyvro.files`, минимум macOS 13, Universal (x86_64 + arm64).
- Чистый AppKit на голом `swiftc`. **Нет** ни Xcode-проекта, ни SwiftPM,
  ни `Package.swift`. Не предлагать их завести без прямой просьбы.
- Описание продукта для пользователей: `RELEASE_README.md`.
  Живой список задач: `ЗАДАЧИ.md` (новое туда добавляется только после
  утверждения).

## Сборка

```bash
./build_app.sh
```

Собирает две оптимизированные архитектуры параллельно, склеивает `lipo`,
кладёт `Info.plist` и иконку, подписывает ad-hoc и печатает путь к готовому
`Qyvro.app` во временной папке. Занимает пару минут.

Что важно знать:

- Компилируется **glob `Sources/*.swift`**, поэтому новый файл в `Sources/`
  подхватывается сам, регистрировать его негде.
- SDK принудительно пинится на `MacOSX15.4.sdk`, если он есть: после частичного
  обновления Command Line Tools безверсионный симлинк уезжает на SDK новее, чем
  понимает установленный Swift.
- Каждый запуск сначала зипует `Sources`, `Resources`, `Tests`, `build_app.sh`
  и `*.md` в `../FPilotMac_Backups/`. Эта папка запрещена на запись в
  `.claude/settings.json`, туда не писать и оттуда ничего не чистить без
  спроса.
- `Attic/` — отложенный код, он вне `Sources/` и не компилируется.

## Смоук-тесты

`Tests/<Имя>Smoke/main.swift` — самостоятельные исполняемые файлы, которые
собираются вместе с исходниками приложения. Тест печатает `... : PASS` и выходит
с 0, либо пишет `FAIL` в stderr и выходит с 1.

Ключевой момент: `Sources/main.swift` — это точка входа приложения, и у теста
своя. **Собирая тест, исключай `Sources/main.swift`**, иначе два top-level кода
конфликтуют.

Проверенная команда (≈35 с, без `-O`):

```bash
xcrun swiftc -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk \
  -target x86_64-apple-macosx13.0 \
  -framework AVFoundation -framework Carbon -framework Cocoa \
  -framework CoreImage -framework CoreVideo -framework IOSurface \
  -framework Metal -framework Quartz -framework QuickLookThumbnailing \
  $(ls Sources/*.swift | grep -v 'Sources/main.swift') \
  Tests/GridGeometrySmoke/main.swift -o /tmp/qyvro-smoke && /tmp/qyvro-smoke
```

Есть тесты: `ClipboardShortcutSmoke`, `FileOperationHistorySmoke`,
`FinderTagStoreSmoke`, `GridGeometrySmoke`, `QuickLookGeometrySmoke`,
`QuickLookSessionCacheSmoke`, `SavedTabGroupsSmoke`, `SpotlightSearchSmoke`.
`Tests/UIWorkspace/` — песочница с файлами и эталонными скриншотами для ручных
проверок интерфейса, не автотест.

Сборка выдаёт ворох предупреждений (deprecated Core Image Kernel Language,
`where` в `case`). Это фон, а не результат твоей правки — не чинить заодно.

## Карта `Sources/`

Примерно 21 000 строк, 21 файл.

| Файл | Что внутри |
|---|---|
| `main.swift` | точка входа, 6 строк |
| `AppDelegate.swift` | меню, валидация пунктов, мост к `QLPreviewPanel` |
| `FilePanel.swift` | **5200 строк**, одна панель проводника: таблица, сетка, поиск, drag'n'drop. Самый тяжёлый файл |
| `Workspace.swift` | вкладки, разделённые панели, сессии окон (`FPWindowSession`) |
| `CoreServices.swift` | `FileItem`, чтение разрешения и длительности вне главного потока, размеры каталогов |
| `FileGridViews.swift` | плитки сетки, заголовки, кнопки-пилюли |
| `UIComponents.swift` | подложки, тонировки, градиенты поверх `NSVisualEffectView` |
| `PreviewWindow.swift` | свой просмотрщик вместо системного Quick Look, сравнение шторкой |
| `PreviewAndSearchSupport.swift` | кэш декодированных превью, геометрия панели, поиск через Spotlight |
| `FilePreviewSidebar.swift` | инспектор в окне; источник истины по выделению остаётся в `FilePanel` |
| `SwipeEffects.swift` | волновой переход при жесте назад-вперёд, Metal/CoreImage |
| `ClipboardModule.swift` | история буфера обмена (пришла из отдельного приложения) |
| `FinderTagStore.swift` | отметки «отобрано» на настоящих метках macOS |
| `FileOperationHistory.swift` | журнал операций, отмена перемещений и удалений |
| `SettingsAndCommands.swift` | окно настроек и палитра команд |
| `SavedTabGroups.swift`, `CutFileState.swift`, `RenameSheet.swift`, `BreadcrumbPathView.swift`, `JumpScroller.swift`, `WindowPresentationAnimator.swift` | по одной подсистеме на файл, имена говорят сами |

## Соглашения

- **Префиксы типов:** `FP` у старого кода (наследство от FPilotMac), `Qyvro`
  у нового. Новые типы называть с `Qyvro`, старые не переименовывать пачкой.
- **Язык:** интерфейс, метки, ошибки — по-русски. Комментарии смешанные, около
  двух третей русские.
- **Комментарии объясняют «почему», а не «что»**: почему системный `NSAlert` не
  подошёл, почему опрос буфера привязан к активности окна, почему тон кладётся
  отдельным видом поверх размытия. Комментарий, пересказывающий соседнюю
  строку кода, здесь лишний.
- **Коммиты:** одна строка по-русски, описывает результат, без префиксов и
  Conventional Commits. Примеры из истории: «Cmd+E стал переключателем»,
  «Тон окна буфера не применялся вообще», «Удаление в сетке без подтверждения».
- Артефакты (`Releases/*.zip`, `*.dmg`, `*.app/`) в git не попадают.

## Грабли

- Замеры производительности в `ЗАДАЧИ.md` сделаны на Intel с интегрированной
  графикой. Тяжёлые эффекты проверяются через `MTLDevice.isLowPower`, у машины
  разработки он как раз срабатывает.
- Ячейка сетки забирает клики на себя ради выделения и перетаскивания. Любой
  новый интерактивный элемент внутри плитки придётся отдельно пробивать через
  `hitTest`, как это уже сделано для точки отметки.
- Отметки живут в настоящих метках Finder, а не в своей базе: они переживают
  переименование и переезд файла, и их видно снаружи приложения. Не заменять
  на локальное хранилище.
