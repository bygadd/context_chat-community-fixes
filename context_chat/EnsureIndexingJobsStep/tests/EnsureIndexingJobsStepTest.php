<?php

declare(strict_types=1);

/**
 * SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

namespace OCA\ContextChat\Tests;

use OCA\ContextChat\BackgroundJobs\SchedulerJob;
use OCA\ContextChat\Logger;
use OCA\ContextChat\Repair\EnsureIndexingJobsStep;
use OCP\BackgroundJob\IJobList;
use OCP\Migration\IOutput;
use PHPUnit\Framework\MockObject\MockObject;
use PHPUnit\Framework\TestCase;

class EnsureIndexingJobsStepTest extends TestCase {
	/** @var MockObject&Logger */
	private $logger;
	/** @var MockObject&IJobList */
	private $jobList;
	/** @var MockObject&IOutput */
	private $output;
	private EnsureIndexingJobsStep $step;

	public function setUp(): void {
		$this->logger = $this->createMock(Logger::class);
		$this->jobList = $this->createMock(IJobList::class);
		$this->output = $this->createMock(IOutput::class);
		$this->step = new EnsureIndexingJobsStep($this->logger, $this->jobList);
	}

	public function testReSeedsSchedulerJobWhenMissing(): void {
		$this->jobList->method('has')->with(SchedulerJob::class, null)->willReturn(false);
		$this->jobList->expects($this->once())->method('add')->with(SchedulerJob::class);
		$this->step->run($this->output);
	}

	public function testDoesNotDuplicateWhenAlreadyScheduled(): void {
		$this->jobList->method('has')->with(SchedulerJob::class, null)->willReturn(true);
		$this->jobList->expects($this->never())->method('add');
		$this->step->run($this->output);
	}
}
