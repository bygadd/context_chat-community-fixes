<?php
// Partial — add this method to lib/Db/QueueMapper.php
// Insert before the count() method.

/**
 * @return list<array{storage_id: int, root_id: int}>
 * @throws \OCP\DB\Exception
 */
public function getQueuedStorageRootTuples(): array {
	$qb = $this->db->getQueryBuilder();
	$qb->selectDistinct('storage_id')
		->addSelect('root_id')
		->from($this->getTableName());
	$result = $qb->executeQuery();
	$out = [];
	while ($row = $result->fetch()) {
		$out[] = ['storage_id' => (int)$row['storage_id'], 'root_id' => (int)$row['root_id']];
	}
	$result->closeCursor();
	return $out;
}
