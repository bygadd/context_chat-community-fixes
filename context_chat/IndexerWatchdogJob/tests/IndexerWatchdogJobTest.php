<?php

declare(strict_types=1);

/**
 * SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

namespace OCA\ContextChat\Tests;

use OCA\ContextChat\BackgroundJobs\IndexerJob;
use OCA\ContextChat\BackgroundJobs\IndexerWatchdogJob;
use OCA\ContextChat\Db\QueueMapper;
use OCA\ContextChat\Logger;
use OCP\App\IAppManager;
use OCP\AppFramework\Services\IAppConfig;
use OCP\AppFramework\Utility\ITimeFactory;
use OCP\BackgroundJob\IJobList;
use PHPUnit\Framework\MockObject\MockObject;
use PHPUnit\Framework\TestCase;

class IndexerWatchdogJobTest extends TestCase {
	/** @var MockObject&ITimeFactory */
	private $time;
	/** @var MockObject&IJobList */
	private $jobList;
	/** @var MockObject&QueueMapper */
	private $queueMapper;
	/** @var MockObject&IAppConfig */
	private $appConfig;
	/** @var MockObject&IAppManager */
	private $appManager;
	/** @var MockObject&Logger */
	private $logger;
	private IndexerWatchdogJob $job;

	public function setUp(): void {
		$this->time = $this->createMock(ITimeFactory::class);
		$this->jobList = $this->createMock(IJobList::class);
		$this->queueMapper = $this->createMock(QueueMapper::class);
		$this->appConfig = $this->createMock(IAppConfig::class);
		$this->appManager = $this->createMock(IAppManager::class);
		$this->logger = $this->createMock(Logger::class);

		// Constructor calls getAppValueInt('watchdog_job_interval', ...) — return the default int
		$this->appConfig->method('getAppValueInt')
			->willReturnCallback(function (string $key, int $default, bool $lazy = false): int {
				return $default;
			});

		$this->job = new IndexerWatchdogJob(
			$this->time,
			$this->jobList,
			$this->queueMapper,
			$this->appConfig,
			$this->appManager,
			$this->logger,
		);
	}

	/**
	 * Happy path: queue has an orphaned tuple with no live IndexerJob → should add one.
	 */
	public function testRevivesMissingConsumers(): void {
		$this->appManager->method('isEnabledForAnyone')->with('app_api')->willReturn(true);
		$this->appConfig->method('getAppValueString')
			->with('auto_indexing', 'true', lazy: true)->willReturn('true');
		// last_indexed_time returns 0 (not yet latched) — override the generic int mock
		$this->appConfig->method('getAppValueInt')
			->willReturnCallback(function (string $key, int $default, bool $lazy = false): int {
				if ($key === 'last_indexed_time') {
					return 0;
				}
				return $default;
			});

		$this->queueMapper->method('getQueuedStorageRootTuples')
			->willReturn([['storage_id' => 3334, 'root_id' => 1492778]]);

		$this->jobList->method('has')->willReturn(false);

		// Assert add is called exactly once, with IndexerJob::class and the correct arg
		$this->jobList->expects($this->once())
			->method('add')
			->with(
				IndexerJob::class,
				$this->callback(function ($arg) {
					// Guard the hash-order regression: storageId must come first
					$this->assertSame(['storageId', 'rootId'], array_keys($arg),
						'arg keys must be storageId then rootId (insertion-order for json_encode hash)');
					$this->assertSame(3334, $arg['storageId']);
					$this->assertSame(1492778, $arg['rootId']);
					return true;
				})
			);

		$this->job->run([]);
	}

	/**
	 * Consumer already registered for the tuple → add must never be called.
	 */
	public function testIdempotentWhenConsumerAlive(): void {
		$this->appManager->method('isEnabledForAnyone')->with('app_api')->willReturn(true);
		$this->appConfig->method('getAppValueString')
			->with('auto_indexing', 'true', lazy: true)->willReturn('true');
		$this->appConfig->method('getAppValueInt')
			->willReturnCallback(function (string $key, int $default, bool $lazy = false): int {
				if ($key === 'last_indexed_time') {
					return 0;
				}
				return $default;
			});

		$this->queueMapper->method('getQueuedStorageRootTuples')
			->willReturn([['storage_id' => 3334, 'root_id' => 1492778]]);

		// has() returns true — consumer already alive
		$this->jobList->method('has')->willReturn(true);
		$this->jobList->expects($this->never())->method('add');

		$this->job->run([]);
	}

	/**
	 * app_api disabled → must bail out without touching the queue or jobList.
	 */
	public function testSilentWhenAppApiDisabled(): void {
		$this->appManager->method('isEnabledForAnyone')->with('app_api')->willReturn(false);

		$this->queueMapper->expects($this->never())->method('getQueuedStorageRootTuples');
		$this->jobList->expects($this->never())->method('add');

		$this->job->run([]);
	}

	/**
	 * last_indexed_time already latched (non-zero) → no queue read, no add.
	 */
	public function testSilentWhenAlreadyLatched(): void {
		$this->appManager->method('isEnabledForAnyone')->with('app_api')->willReturn(true);
		$this->appConfig->method('getAppValueString')
			->with('auto_indexing', 'true', lazy: true)->willReturn('true');
		$this->appConfig->method('getAppValueInt')
			->willReturnCallback(function (string $key, int $default, bool $lazy = false): int {
				if ($key === 'last_indexed_time') {
					return 1749600000; // non-zero → already latched
				}
				return $default;
			});

		$this->queueMapper->expects($this->never())->method('getQueuedStorageRootTuples');
		$this->jobList->expects($this->never())->method('add');

		$this->job->run([]);
	}

	/**
	 * Queue is empty → no add needed.
	 */
	public function testSilentWhenQueueEmpty(): void {
		$this->appManager->method('isEnabledForAnyone')->with('app_api')->willReturn(true);
		$this->appConfig->method('getAppValueString')
			->with('auto_indexing', 'true', lazy: true)->willReturn('true');
		$this->appConfig->method('getAppValueInt')
			->willReturnCallback(function (string $key, int $default, bool $lazy = false): int {
				if ($key === 'last_indexed_time') {
					return 0;
				}
				return $default;
			});

		$this->queueMapper->method('getQueuedStorageRootTuples')->willReturn([]);
		$this->jobList->expects($this->never())->method('add');

		$this->job->run([]);
	}
}
