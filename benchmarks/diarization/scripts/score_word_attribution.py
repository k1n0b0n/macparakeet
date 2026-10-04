#!/usr/bin/env python3
"""Word-level speaker attribution of saved diarization runs, on the app's ASR words.

Each ASR word gets the reference speaker active over its whole span; a word that
touches no reference speech, two speakers, or falls outside the UEM is not
scored. Predicted segments are assigned to words by a copy of the app's
SpeakerMerger, under three policies: `raw` (no smoothing), `app` (the merger as
shipped: fill gaps and merge one-word flips) and `keep` (fill gaps only, to
measure what the one-word merge costs). Predicted speakers map one-to-one to reference speakers by
greedy agreement; a nil or unmapped word counts as wrong. Accuracy is reported
by the length of the reference turn the word belongs to, because one-word turns
are the replies that smoothing can erase (#1046).

This is not DER or cpWER: overlapped speech and ASR errors are excluded.
No audio, inference, downloads, or third-party Python packages are needed.
"""
from __future__ import annotations

import argparse
import bisect
import collections
import json
from pathlib import Path

POLICIES = ("raw", "app", "keep")
BUCKETS = ("1", "2", "3-5", "6+", "all")


def read_rttm(path: Path) -> list[tuple[int, int, str]]:
    turns = []
    for line in path.read_text().splitlines():
        fields = line.split()
        if fields and fields[0] == "SPEAKER":
            start = round(float(fields[3]) * 1000)
            turns.append((start, start + round(float(fields[4]) * 1000), fields[7]))
    return sorted(turns)


def read_uem(path: Path) -> list[tuple[int, int]]:
    regions = []
    for line in path.read_text().splitlines():
        fields = line.split()
        if len(fields) >= 4:
            regions.append((round(float(fields[2]) * 1000), round(float(fields[3]) * 1000)))
    return regions


def label_words(words: list[dict], turns: list[tuple[int, int, str]], uem: list[tuple[int, int]]) -> list[str | None]:
    """Reference speaker of each word, or None when it is not scorable."""
    starts = [turn[0] for turn in turns]
    longest = max((end - start for start, end, _ in turns), default=0)
    labels = []
    for word in words:
        start, end = word["startMs"], word["endMs"]
        inside = any(lo <= start and end <= hi for lo, hi in uem)
        first = bisect.bisect_left(starts, start - longest)
        last = bisect.bisect_left(starts, end)
        speakers = {spk for s, e, spk in turns[first:last] if s < end and start < e}
        covering = {spk for s, e, spk in turns[first:last] if s <= start and end <= e}
        labels.append(next(iter(covering)) if inside and len(speakers) == 1 and covering else None)
    return labels


def merge(words: list[dict], segments: list[dict], policy: str) -> list[str | None]:
    """Mirror of SpeakerMerger.mergeWordTimestampsWithSpeakers."""
    ordered = sorted(segments, key=lambda s: s["startMs"])
    assigned, index = [], 0
    for word in words:
        while index < len(ordered) and ordered[index]["endMs"] <= word["startMs"]:
            index += 1
        best, best_overlap, cursor = None, 0, index
        while cursor < len(ordered) and ordered[cursor]["startMs"] < word["endMs"]:
            overlap = min(word["endMs"], ordered[cursor]["endMs"]) - max(word["startMs"], ordered[cursor]["startMs"])
            if overlap > best_overlap:
                best, best_overlap = ordered[cursor]["speakerId"], overlap
            cursor += 1
        assigned.append(best if best_overlap > 0 else None)
    if policy == "raw" or len(assigned) < 3:
        return assigned
    smoothed, start = list(assigned), 0
    while start < len(assigned):
        end = start + 1
        while end < len(assigned) and assigned[end] == assigned[start]:
            end += 1
        previous = assigned[start - 1] if start > 0 else None
        following = assigned[end] if end < len(assigned) else None
        if previous is not None and previous == following:
            run = assigned[start]
            if run is None or (policy == "app" and end - start == 1 and run != previous):
                smoothed[start:end] = [previous] * (end - start)
        start = end
    return smoothed


def bucket(length: int) -> str:
    return "1" if length == 1 else "2" if length == 2 else "3-5" if length <= 5 else "6+"


def score(labels: list[str | None], predicted: list[str | None]) -> dict:
    pairs = [(ref, pred) for ref, pred in zip(labels, predicted) if ref is not None]
    agreement = collections.Counter((pred, ref) for ref, pred in pairs if pred is not None)
    mapping, used = {}, set()
    for (pred, ref), _ in sorted(agreement.items(), key=lambda item: (-item[1], item[0])):
        if pred not in mapping and ref not in used:
            mapping[pred] = ref
            used.add(ref)
    totals, correct = collections.Counter(), collections.Counter()
    start = 0
    while start < len(pairs):
        end = start + 1
        while end < len(pairs) and pairs[end][0] == pairs[start][0]:
            end += 1
        for ref, pred in pairs[start:end]:
            for name in (bucket(end - start), "all"):
                totals[name] += 1
                correct[name] += mapping.get(pred) == ref
        start = end
    spurious = sum(
        1 for (ref_a, pred_a), (ref_b, pred_b) in zip(pairs, pairs[1:])
        if ref_a == ref_b and pred_a is not None and pred_b is not None and pred_a != pred_b
    )
    return {
        "words": totals, "correct": correct,
        "nil": sum(pred is None for _, pred in pairs), "spurious": spurious,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--condition", default="mhm")
    parser.add_argument("--reference-root", type=Path, required=True)
    parser.add_argument("--asr-root", type=Path, required=True,
                        help="macparakeet-cli JSON per recording id, with wordTimestamps")
    parser.add_argument("--predictions", action="append", required=True, metavar="BACKEND=DIRECTORY")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    records = [r for r in json.loads(args.manifest.read_text())["recordings"] if r["condition"] == args.condition]
    report = {}
    print(f"{'backend':24} {'policy':6} " + " ".join(f"{name:>7}" for name in BUCKETS) + f" {'nil%':>6} {'spur/1k':>8}")
    for value in args.predictions:
        name, directory = value.split("=", 1)
        sums = {policy: collections.Counter() for policy in POLICIES}
        for record in records:
            rid = record["id"]
            words = sorted(json.loads((args.asr_root / f"{rid}.json").read_text())["wordTimestamps"],
                           key=lambda w: w["startMs"])
            words = [w for w in words if w["endMs"] > w["startMs"]]
            labels = label_words(words, read_rttm(args.reference_root / f"{rid}.rttm"),
                                 read_uem(args.reference_root / f"{rid}.uem"))
            segments = json.loads((Path(directory) / f"{rid}.json").read_text())["segments"]
            for policy in POLICIES:
                result = score(labels, merge(words, segments, policy))
                sums[policy].update({f"words:{k}": v for k, v in result["words"].items()})
                sums[policy].update({f"correct:{k}": v for k, v in result["correct"].items()})
                sums[policy].update(nil=result["nil"], spurious=result["spurious"])
        report[name] = {}
        for policy in POLICIES:
            total = sums[policy]
            words = total["words:all"]
            accuracy = {b: 100 * total[f"correct:{b}"] / total[f"words:{b}"] for b in BUCKETS if total[f"words:{b}"]}
            report[name][policy] = {
                "accuracyPercentByReferenceTurnWords": accuracy,
                "wordsByReferenceTurnWords": {b: total[f"words:{b}"] for b in BUCKETS},
                "nilPercent": 100 * total["nil"] / words,
                "spuriousSwitchesPer1000Words": 1000 * total["spurious"] / words,
            }
            print(f"{name:24} {policy:6} " + " ".join(f"{accuracy.get(b, 0):7.1f}" for b in BUCKETS)
                  + f" {100 * total['nil'] / words:6.2f} {1000 * total['spurious'] / words:8.2f}")
    if args.output:
        args.output.write_text(json.dumps(report, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
