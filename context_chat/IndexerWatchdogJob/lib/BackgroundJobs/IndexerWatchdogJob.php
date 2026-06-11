<?php

declare(strict_types=1);

/**
 * SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

namespace OCA\ContextChat\BackgroundJobs;

use OCA\ContextChat\Db\QueueMapper;
use OCA\ContextChat\Logger;
use OCP\App\IAppManager;
use OCP\AppFramework\Services\IAppConfig;
use OCP\AppFramework\Utility\ITimeFactory;
use OCP\BackgroundJob\IJobList;
use OCP\BackgroundJob\TimedJob;

/**
 * Continuous self-heal for the indexing chain. The chain (SchedulerJob ->
 * StorageCrawlJob -> IndexerJob) is one-shot and self-removing; the only IndexerJob
 * creator is QueueService::scheduleJob(), reached only AFTER insertIntoQueue()'s
 * existsQueueItem() short-circuit. So rows already in oc_context_chat_queue can be
 * left with no consumer and last_indexed_time never latches. Declared in
 * info.xml <background-jobs> so NC re-adds it on every upgrade and never deletes it.
 * Each tick it seeds the missing IndexerJob per queued (storage,root), bypassing
 * the buggy insertIntoQueue path.
 */
class IndexerWatchdogJob extends TimedJob {
	public const DEFAULT_JOB_INTERVAL = 60 * 60; // 1h

	public function __construct(
		ITimeFactory $time,
		private IJobList $jobList,
		private QueueMapper $queueMapper,
		private IAppConfig $appConfig,
		private IAppManager $appManager,
		private Logger $logger,
	) {
		parent::__construct($time);
		$this->setInterval(
			$this->appConfig->getAppValueInt('watchdog_job_interval', self::DEFAULT_JOB_INTERVAL, lazy: true)
		);
		$this->setAllowParallelRuns(false);
		$this->setTimeSensitivity(self::TIME_INSENSITIVE);
	}

	protected function run($argument): void {
		if (!$this->appManager->isEnabledForAnyone('app_api')) {
			return;
		}
		// Mirror IndexerJob's auto_indexing guard EXACTLY (IndexerJob.php line 94):
		// getAppValueString('auto_indexing', 'true', lazy: true) === 'false'
		if ($this->appConfig->getAppValueString('auto_indexing', 'true', lazy: true) === 'false') {
			return;
		}
		if ($this->appConfig->getAppValueInt('last_indexed_time', 0, lazy: true) !== 0) {
			return;
		}
		try {
			$tuples = $this->queueMapper->getQueuedStorageRootTuples();
		} catch (\OCP\DB\Exception $e) {
			$this->logger->error('[IndexerWatchdog] Could not read queue tuples', ['exception' => $e]);
			return;
		}
		if (empty($tuples)) {
			return;
		}
		$revived = 0;
		foreach ($tuples as $t) {
			$arg = ['storageId' => $t['storage_id'], 'rootId' => $t['root_id']];
			if ($this->jobList->has(IndexerJob::class, $arg)) {
				continue;
			}
			$this->jobList->add(IndexerJob::class, $arg);
			$revived++;
		}
		if ($revived > 0) {
			$this->logger->warning('[IndexerWatchdog] Revived ' . $revived
				. ' orphaned IndexerJob(s) for queued-but-unconsumed tuples',
				['tuplesQueued' => count($tuples)]);
		}
	}
}
