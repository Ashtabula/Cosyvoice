# test_decode_fragmentation.py
# Requirement: verify interval accounting does not mistake CPU boundary time or nested hardware rows for fragmentation.
import unittest
from audit_decode_fragmentation import interval_metrics


class IntervalAccounting(unittest.TestCase):
    def test_single_interval_excludes_boundaries(self):
        result = interval_metrics(0, 20_000_000, [(3_000_000, 18_000_000)])
        self.assertEqual(result['internalGapMilliseconds'], 0)
        self.assertEqual(result['preANEBoundaryMilliseconds'], 3)
        self.assertEqual(result['postANEBoundaryMilliseconds'], 2)
        self.assertEqual(result['aneIntervalCoverage'], .75)

    def test_multiple_islands(self):
        result = interval_metrics(0, 20_000_000, [(2_000_000, 6_000_000), (9_000_000, 17_000_000)])
        self.assertEqual(result['internalGapMilliseconds'], 3)
        self.assertEqual(result['longestANEIntervalMilliseconds'], 8)
        self.assertEqual(result['fragmentationRatio'], .15)

    def test_nested_rows_do_not_double_count(self):
        result = interval_metrics(0, 20_000_000, [(2_000_000, 18_000_000), (4_000_000, 10_000_000)])
        self.assertEqual(result['aneIntervalCount'], 2)
        self.assertEqual(result['mergedANEIntervalCount'], 1)
        self.assertEqual(result['totalANEIntervalMilliseconds'], 16)

    def test_overlapping_and_touching_rows(self):
        result = interval_metrics(0, 20_000_000, [(2_000_000, 8_000_000), (6_000_000, 12_000_000), (12_000_000, 18_000_000)])
        self.assertEqual(result['internalGapCount'], 0)
        self.assertEqual(result['totalANEIntervalMilliseconds'], 16)

    def test_missing_intervals_not_implicitly_clean(self):
        result = interval_metrics(0, 20_000_000, [])
        self.assertEqual(result['aneIntervalCount'], 0)
        self.assertIsNone(result['preANEBoundaryMilliseconds'])
        self.assertEqual(result['aneIntervalCoverage'], 0)

    def test_reject_cross_boundary(self):
        with self.assertRaises(AssertionError):
            interval_metrics(0, 20, [(3, 21)])


if __name__ == '__main__':
    unittest.main()
# Purpose: meaningful synthetic accounting gates for physical trace analysis, not runtime/model tests.
# Upstream audit_decode_fragmentation.py; Python3/macOS; generated2026-10-06 America/New_York. New file.
