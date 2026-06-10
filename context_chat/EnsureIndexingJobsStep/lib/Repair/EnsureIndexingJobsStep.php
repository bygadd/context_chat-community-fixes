<?php

declare(strict_types=1);

/**
 * SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

namespace OCA\ContextChat\Repair;

use OCA\ContextChat\BackgroundJobs\SchedulerJob;
use OCA\ContextChat\Logger;
use OCP\BackgroundJob\IJobList;
use OCP\Migration\IOutput;
use OCP\Migration\IRepairStep;

/**
 * Runs on every app upgrade (post-migration). The indexing-job chain
 * (SchedulerJob -> StorageCrawlJob -> IndexerJob) is one-shot and self-removing
 * by design: once the initial crawl finished it self-deleted. It is seeded only
 * by AppInstallStep, which is an <install>-only repair step and therefore never
 * runs on `occ upgrade`. So after an upgrade the chain stays dead, the file
 * queue gains no consumer, and `last_indexed_time` never latches -> the
 * "initial indexing is still running" banner shows forever.
 *
 * This step idempotently re-seeds SchedulerJob when it is missing, so a stalled
 * install self-heals on the next upgrade. Mirrors Recognize, whose InstallDeps
 * step is wired under both <install> and <post-migration>.
 */
class EnsureIndexingJobsStep implements IRepairStep {

	public function __construct(
		private Logger $logger,
		private IJobList $jobList,
	) {
	}

	public function getName(): string {
		return 'Ensure Context Chat indexing jobs are scheduled';
	}

	public function run(IOutput $output): void {
		if ($this->jobList->has(SchedulerJob::class, null)) {
			return;
		}
		$this->logger->info('SchedulerJob missing after upgrade; re-seeding the Context Chat indexing job chain');
		$this->jobList->add(SchedulerJob::class);
	}
}
