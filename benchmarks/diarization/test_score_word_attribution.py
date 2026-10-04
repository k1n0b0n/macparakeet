#!/usr/bin/env python3
"""Word attribution scorer tests: merger parity with SpeakerMergerTests and reference labelling."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "scripts"))
from score_word_attribution import label_words, merge, score


def words(*spans):
    return [{"startMs": start, "endMs": end} for start, end in spans]


def segments(*spans):
    return [{"speakerId": spk, "startMs": start, "endMs": end} for spk, start, end in spans]


class MergerParityTests(unittest.TestCase):
    flip_words = words((0, 400), (400, 480), (480, 900))
    flip_segments = segments(("S1", 0, 400), ("S2", 400, 480), ("S1", 480, 900))

    def test_app_policy_merges_an_isolated_one_word_flip(self):
        self.assertEqual(merge(self.flip_words, self.flip_segments, "app"), ["S1", "S1", "S1"])

    def test_keep_policy_keeps_it(self):
        self.assertEqual(merge(self.flip_words, self.flip_segments, "keep"), ["S1", "S2", "S1"])

    def test_two_word_flip_is_not_smoothed(self):
        result = merge(words((0, 300), (300, 600), (600, 900), (900, 1200)),
                       segments(("S1", 0, 300), ("S2", 300, 900), ("S1", 900, 1200)), "app")
        self.assertEqual(result, ["S1", "S2", "S2", "S1"])

    def test_nil_gap_between_the_same_speaker_is_filled_by_both_policies(self):
        spans = words((0, 400), (1200, 1400), (2500, 2900))
        segs = segments(("S1", 0, 1000), ("S1", 2000, 4000))
        self.assertEqual(merge(spans, segs, "raw"), ["S1", None, "S1"])
        self.assertEqual(merge(spans, segs, "app"), ["S1", "S1", "S1"])
        self.assertEqual(merge(spans, segs, "keep"), ["S1", "S1", "S1"])

    def test_most_overlap_wins_and_earlier_segment_breaks_ties(self):
        result = merge(words((0, 100), (90, 210)), segments(("S1", 0, 150), ("S2", 150, 210)), "raw")
        self.assertEqual(result, ["S1", "S1"])


class ScoringTests(unittest.TestCase):
    def test_words_touching_two_speakers_or_outside_the_uem_are_not_scored(self):
        turns = [(0, 1000, "A"), (900, 2000, "B")]
        labels = label_words(words((100, 300), (950, 1050), (1500, 1700), (2100, 2200)), turns, [(0, 1600)])
        self.assertEqual(labels, ["A", None, None, None])

    def test_one_word_turn_accuracy_and_nil_words(self):
        result = score(["A", "A", "B", "A", "A"], ["S1", "S1", "S1", "S1", None])
        self.assertEqual(result["words"]["1"], 1)
        self.assertEqual(result["correct"]["1"], 0)
        self.assertEqual(result["correct"]["all"], 3)
        self.assertEqual(result["nil"], 1)


if __name__ == "__main__":
    unittest.main()
