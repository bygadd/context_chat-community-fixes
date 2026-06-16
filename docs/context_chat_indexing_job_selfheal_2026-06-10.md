# context_chat — Self-heal на indexing-job веригата (дизайн-спецификация)

**Дата:** 2026-06-10 · **App:** context_chat **v5.3.1** (NC 33.0.5, `the host`) · **:** Incident
**Статус:** дизайн ОДОБРЕН от Йоан (2026-06-10); предстои implementation plan (writing-plans).
**Цел:** context_chat сам да възстановява (self-heal) file-indexing job-овете си при всеки upgrade, за да не „виси завинаги" банерът „initial indexing still running" и опашката да се източва — БЕЗ еднократно ръчно пре-регистриране, което се губи при следващ app update.

---

## 1. Коренова причина (потвърдена срещу реалния v5.3.1 source; 7-агентен анализ + 2 adversarial верификатора = supported)

1. `appinfo/info.xml` `<background-jobs>` декларира само **3** job-а — `FileSystemListenerJob`, `ActionJob`, `RotateLogsJob`. Тях NC core идемпотентно ги пресажда при всеки `app:update` → те са живи и здрави.
2. Indexing-веригата НЕ е в info.xml. Добавя се само runtime:
   - `AppInstallStep` (repair step, **`<install>`-only** — НЕ се пуска при `occ upgrade`) → `jobList->add(SchedulerJob)` (seed-ът е **неguarded**).
   - `SchedulerJob` (QueuedJob, one-shot): нулира `last_indexed_time=0` + `indexed_files_count=0`, фановете `StorageCrawlJob` за всеки mount, после **`remove(self)` — трие се сам**.
   - `StorageCrawlJob` (one-shot): за всеки файл → `QueueService::insertIntoQueue`; `scheduleAfter(self)` само ако mount-ът има нови файли → **спира + се трие сам** като свърши.
   - `IndexerJob` (TimedJob, **единственият писач на `last_indexed_time`** чрез `setInitialIndexCompletion()`): създава се САМО като страничен ефект на `QueueService::scheduleJob`, която се вика САМО при вкарване на НОВ ред в опашката.
3. **`Application::boot()` е ПРАЗЕН** — няма идемпотентен `jobList->add()` self-heal на ниво bootstrap.
4. **Капанът:** `QueueService::insertIntoQueue()` прави early-return на `existsQueueItem($file)` **ПРЕДИ** `scheduleJob()`. При вече пълна опашка (24595 реда) нито един нов IndexerJob не се ражда.

**Следствие:** Първоначалният обход е приключил под минала версия (`indexed_files_count=32028`, `last_indexed_file_id=2753924`). SchedulerJob+StorageCrawlJob са се самоизтрили by design. 4.x→5.x ъпгрейдът не пипа `oc_jobs` и няма `<post-migration>` repair → **нищо не пресажда веригата**. Опашката (24595) е без консуматор; `last_indexed_time=0` завинаги → двата банера (admin „initial indexing still running" + Assistant „has not finished indexing") висят постоянно.

context_chat е **нормален PHP server app** (не ExApp) → `<post-migration>` repair steps СЕ ИЗПЪЛНЯВАТ при app update/`occ upgrade`. Това е носещата основа на фикса.

## 2. Фикс — траен self-heal (одобрен подход A)

**Компонент 1 — Repair step на всеки upgrade (идемпотентен, guarded):**
- Нов `lib/Migration/EnsureIndexingJobsRepairStep.php : IRepairStep`.
- `run()`: `if (!$this->jobList->has(SchedulerJob::class, null)) { $this->jobList->add(SchedulerJob::class); }`
  - **`has()`-guard-ът е ЗАДЪЛЖИТЕЛЕН** — текущият seed в `AppInstallStep` е неguarded; без guard repair-ът би дублирал `SchedulerJob` при всеки upgrade.
- Закачен в `info.xml`: `<repair-steps><post-migration>OCA\ContextChat\Migration\EnsureIndexingJobsRepairStep</post-migration></repair-steps>` (до сегашния `<install>`).
- **Прецедент:** sibling-апът **Recognize** (от който тези job-ове са форкнати — license headers) закача своя `InstallDeps` step и под `<install>`, и под `<post-migration>` — приет upstream модел.
- Ефект: всеки upgrade → NC пуска post-migration repair → пресажда `SchedulerJob` ако липсва → веригата `StorageCrawlJob → IndexerJob` се възстановява → `last_indexed_time` се вдига → банерите изчезват.

**Компонент 2 — Еднократно възстановяване + източване на заседналия backlog (при внедряване):**
- `occ background-job:add 'OCA\ContextChat\BackgroundJobs\SchedulerJob'` — пресажда веригата веднага (preferred immediate-recovery; НЕ disable/enable — `<install>` repair НЕ се пуска при enable).
- ⚠️ Re-crawl НЕ източва сегашните 24595 реда (заради `existsQueueItem` early-return) → източваме явно с `occ context_chat:scan <user>` (re-enqueue → ражда IndexerJob-ове).
- Верификация: опашката пада към 0; `last_indexed_time > 0`; банерите изчезват; CCB backend консуматорът е здрав (app_api enabled, auto_indexing не е спрян — проверено); 0 дублирани job-а.

**Компонент 3 — Устойчивост:**
- Пачът е локална промяна на third-party PHP app → **губи се при app update** → задължителни: (а) **PR към общността** (постоянно след merge+release — виж §4); (б) пачът + re-apply runbook в `/Users/bygadd/CLAUDE/`; (в) **ботът няма write до `apps/` → Йоан прилага живия пач.**

## 3. Тестване
- Unit/симулация: махам `SchedulerJob` от `oc_jobs` → пускам repair (`occ maintenance:repair` или upgrade path) → `has()`-guard добавя точно 1 SchedulerJob; повторно пускане → НЕ дублира.
- Live верификация (по §2): drain на опашката, latch на флага, изчистване на банерите, без дублирани job-ове.

## 4. Връзка с ЦЯЛОСТНИЯ PR към общността (всички context_chat пачове до момента)

Целта (Йоан, 2026-06-10): при **финална, изчистена от бъгове версия на context_chat** да предложим ОБОБЩЕН принос с всички разработени пачове. Инвентар:

| # | Пач | Repo | Тип | Статус ||
|---|---|---|---|---|---|
| 1 | multipart-CR freeze fix | context_chat_backend | Python | LIVE (container patch) | |
| 2 | fork-deadlock freeze fix | context_chat_backend | Python | LIVE | |
| 3 | recv-leak / lease fix (+тест) | context_chat_backend | Python | LIVE | |
| 4 | child-log relay (ccb.log) | context_chat_backend | Python | LIVE | |
| 5 | SMB `fopen` non-seekable → unconditional `CachingStream` (LangRopeService) | **context_chat (PHP)** | PHP | Йоан прилага | |
| 6 | **indexing-job self-heal (post-migration IRepairStep)** ← ТОЗИ | **context_chat (PHP)** | PHP | дизайн одобрен | |

- Реално = **2 upstream PR-а**: един към `nextcloud/context_chat` (PHP: #5, #6) и един към `nextcloud/context_chat_backend` (Python: #1-4). Worker dup-fix-ът (NC-core `nextcloud/server`) е ОТДЕЛЕН repo и вече е PR-нат от другата инстанция — не е част от този принос.
- Всеки пач да носи: проблем, root cause, fix, тест, версия. Този doc + аналозите `context_chat_*_2026-06-*.md` са изходният материал за PR-описанията.

## 5. Файлове (за плана)
- Create: `context_chat/lib/Migration/EnsureIndexingJobsRepairStep.php`
- Modify: `context_chat/appinfo/info.xml` (+`<post-migration>`)
- (Опц.) рефактор: извади seed-а в споделен метод, ползван и от `AppInstallStep`, и от новия step (DRY).
