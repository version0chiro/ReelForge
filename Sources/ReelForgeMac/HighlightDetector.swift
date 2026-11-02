import Foundation

enum HighlightDetector {
    private static func clamp(_ value: Double, _ minimum: Double = 0, _ maximum: Double = 1) -> Double {
        min(maximum, max(minimum, value))
    }

    private static func percentile(_ values: [Double], _ quantile: Double) -> Double {
        let sorted = values.filter(\.isFinite).sorted()
        guard let first = sorted.first else { return 0 }
        guard sorted.count > 1 else { return first }
        let position = clamp(quantile) * Double(sorted.count - 1)
        let lower = Int(floor(position))
        let upper = Int(ceil(position))
        let weight = position - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }

    private static func normalize(_ values: [Double]) -> [Double] {
        guard !values.isEmpty else { return [] }
        let low = percentile(values, 0.2)
        var high = percentile(values, 0.92)
        let maximum = values.filter(\.isFinite).max() ?? low
        if high - low < 0.000_000_001, maximum - low >= 0.000_000_001 {
            high = maximum
        }
        let range = high - low
        guard range.isFinite, range >= 0.000_000_001 else {
            return values.map { _ in 0 }
        }
        return values.map { clamp(($0 - low) / range) }
    }

    static func score(_ samples: [FeatureSample], audioWeight: Double) -> [ScoredSample] {
        let rms = normalize(samples.map(\.audioRMS))
        let onset = normalize(samples.map(\.audioOnset))
        let motion = normalize(samples.map(\.motion))
        let scene = normalize(samples.map(\.scene))
        let hasAudio = rms.contains { $0 > 0.02 } || onset.contains { $0 > 0.02 }
        let hasVisual = motion.contains { $0 > 0.02 } || scene.contains { $0 > 0.02 }
        var effectiveAudioWeight = clamp(audioWeight)
        if !hasAudio, hasVisual { effectiveAudioWeight = 0 }
        if hasAudio, !hasVisual { effectiveAudioWeight = 1 }

        return samples.indices.map { index in
            let audio = clamp(rms[index] * 0.62 + onset[index] * 0.38)
            let visual = clamp(motion[index] * 0.7 + scene[index] * 0.3)
            let synergy = min(audio, visual) * 0.12
            return ScoredSample(
                sample: samples[index],
                audioScore: audio,
                motionScore: motion[index],
                sceneScore: scene[index],
                visualScore: visual,
                score: clamp(
                    audio * effectiveAudioWeight
                        + visual * (1 - effectiveAudioWeight)
                        + synergy
                )
            )
        }
    }

    static func detect(
        sources: [VideoSource],
        settings: DetectionSettings
    ) -> (highlights: [Highlight], scoredBySource: [UUID: [ScoredSample]]) {
        let validSources = sources.enumerated().filter { !$0.element.samples.isEmpty && $0.element.duration > 0 }
        guard !validSources.isEmpty else { return ([], [:]) }
        let sequenceDuration = clamp(settings.sequenceDuration, 1, 8)
        let targetDuration = clamp(settings.targetDuration, 3, 60)
        let desiredCount = max(1, Int(ceil(targetDuration / sequenceDuration)))
        var scoredBySource: [UUID: [ScoredSample]] = [:]
        var allCandidates: [Highlight] = []

        for (sourceIndex, source) in validSources {
            let scored = score(source.samples, audioWeight: settings.audioWeight)
            scoredBySource[source.id] = scored
            allCandidates += candidates(
                source: source,
                sourceIndex: sourceIndex,
                scored: scored,
                desiredCount: desiredCount,
                settings: settings
            )
        }

        let ranked = allCandidates.sorted { $0.score > $1.score }
        var selected: [Highlight] = []
        var selectedIDs = Set<UUID>()

        func append(_ candidate: Highlight) {
            guard selected.count < desiredCount, !selectedIDs.contains(candidate.id) else { return }
            selected.append(candidate)
            selectedIDs.insert(candidate.id)
        }

        if desiredCount >= validSources.count {
            for (sourceIndex, _) in validSources {
                if let best = ranked.first(where: { $0.sourceIndex == sourceIndex }) {
                    append(best)
                }
            }
        }
        ranked.forEach(append)

        selected.sort {
            $0.sourceIndex == $1.sourceIndex
                ? $0.start < $1.start
                : $0.sourceIndex < $1.sourceIndex
        }
        if settings.order == .hookFirst, selected.count > 1,
           let hookIndex = selected.indices.max(by: { selected[$0].score < selected[$1].score }) {
            let hook = selected.remove(at: hookIndex)
            var diverseOrder = [hook]
            var seenSources = Set([hook.sourceID])
            while !selected.isEmpty {
                let nextIndex = selected.firstIndex { !seenSources.contains($0.sourceID) } ?? 0
                let next = selected.remove(at: nextIndex)
                diverseOrder.append(next)
                seenSources.insert(next.sourceID)
            }
            selected = diverseOrder
        }

        var usedDuration = 0.0
        for index in selected.indices {
            let remaining = targetDuration - usedDuration
            if remaining <= 0 {
                selected[index].end = selected[index].start
            } else if selected[index].duration > remaining {
                selected[index].end = selected[index].start + remaining
            }
            usedDuration += selected[index].duration
        }
        selected.removeAll { $0.duration < 0.5 }
        return (selected, scoredBySource)
    }

    private static func candidates(
        source: VideoSource,
        sourceIndex: Int,
        scored: [ScoredSample],
        desiredCount: Int,
        settings: DetectionSettings
    ) -> [Highlight] {
        guard !scored.isEmpty else { return [] }
        let clipDuration = clamp(settings.sequenceDuration, 1, 8)
        if source.duration <= settings.targetDuration + 0.15 {
            let peak = scored.max(by: { $0.score < $1.score }) ?? scored[0]
            let metrics = sequenceMetrics(scored: scored, peak: peak, duration: source.duration)
            return [
                makeHighlight(
                    source: source,
                    sourceIndex: sourceIndex,
                    start: 0,
                    end: source.duration,
                    peak: peak,
                    metrics: metrics,
                    scored: scored,
                    clipDuration: source.duration
                ),
            ]
        }

        let averageStep = scored.count > 1
            ? max(0.02, source.duration / Double(scored.count - 1))
            : clipDuration
        let peakRadius = max(1, Int(round((clipDuration * 0.42) / averageStep)))
        let threshold = 0.7 - clamp(settings.sensitivity) * 0.36
        var localPeaks: [(ScoredSample, SequenceMetrics)] = []

        for index in scored.indices {
            let lower = max(0, index - peakRadius)
            let upper = min(scored.count - 1, index + peakRadius)
            let isPeak = (lower...upper).allSatisfy {
                $0 == index || scored[$0].score <= scored[index].score
            }
            if isPeak {
                localPeaks.append((
                    scored[index],
                    sequenceMetrics(scored: scored, peak: scored[index], duration: clipDuration)
                ))
            }
        }

        localPeaks.sort {
            let leftPasses = $0.1.score >= threshold
            let rightPasses = $1.1.score >= threshold
            if leftPasses != rightPasses { return leftPasses }
            return $0.1.score > $1.1.score
        }

        var selected: [Highlight] = []
        let minimumGap = min(1, clipDuration * 0.3)
        for (peak, metrics) in localPeaks {
            var start = clamp(
                peak.sample.time - clipDuration * 0.46,
                0,
                max(0, source.duration - clipDuration)
            )
            let end = min(source.duration, start + clipDuration)
            if end - start < clipDuration, start > 0 {
                start = max(0, end - clipDuration)
            }
            let collides = selected.contains {
                start < $0.end + minimumGap && end > $0.start - minimumGap
            }
            if collides { continue }
            selected.append(
                makeHighlight(
                    source: source,
                    sourceIndex: sourceIndex,
                    start: start,
                    end: end,
                    peak: peak,
                    metrics: metrics,
                    scored: scored,
                    clipDuration: clipDuration
                )
            )
            if selected.count >= desiredCount { break }
        }

        if selected.isEmpty, let peak = scored.max(by: { $0.score < $1.score }) {
            let metrics = sequenceMetrics(scored: scored, peak: peak, duration: clipDuration)
            let start = clamp(
                peak.sample.time - clipDuration * 0.46,
                0,
                max(0, source.duration - clipDuration)
            )
            selected.append(
                makeHighlight(
                    source: source,
                    sourceIndex: sourceIndex,
                    start: start,
                    end: min(source.duration, start + clipDuration),
                    peak: peak,
                    metrics: metrics,
                    scored: scored,
                    clipDuration: clipDuration
                )
            )
        }
        return selected
    }

    private struct SequenceMetrics {
        let score: Double
        let peakScore: Double
        let strength: Double
    }

    private static func sequenceMetrics(
        scored: [ScoredSample],
        peak: ScoredSample,
        duration: Double
    ) -> SequenceMetrics {
        let start = peak.sample.time - duration * 0.46
        let end = peak.sample.time + duration * 0.54
        let window = scored.filter { $0.sample.time >= start && $0.sample.time <= end }
        let usable = window.isEmpty ? [peak] : window
        let scores = usable.map(\.score)
        let sustained = percentile(scores, 0.68)
        let average = scores.reduce(0, +) / Double(scores.count)
        let synergy = usable.map { min($0.audioScore, $0.visualScore) }.reduce(0, +)
            / Double(usable.count)
        return SequenceMetrics(
            score: clamp(peak.score * 0.55 + sustained * 0.25 + average * 0.12 + synergy * 0.08),
            peakScore: peak.score,
            strength: sustained
        )
    }

    private static func makeHighlight(
        source: VideoSource,
        sourceIndex: Int,
        start: Double,
        end: Double,
        peak: ScoredSample,
        metrics: SequenceMetrics,
        scored: [ScoredSample],
        clipDuration: Double
    ) -> Highlight {
        let radius = max(0.5, clipDuration * 0.7)
        let nearby = scored.filter { abs($0.sample.time - peak.sample.time) <= radius }
        var totalWeight = 0.0
        var weightedCrop = 0.0
        for sample in nearby {
            let proximity = 1 - abs(sample.sample.time - peak.sample.time) / radius
            let weight = max(0.05, sample.motionScore) * max(0, proximity)
            weightedCrop += sample.sample.cropX * weight
            totalWeight += weight
        }
        let cropX = totalWeight > 0 ? clamp(weightedCrop / totalWeight, 0.08, 0.92) : 0.5
        var reasons: [String] = []
        if peak.audioScore >= 0.52 { reasons.append("sound") }
        if peak.motionScore >= 0.52 { reasons.append("motion") }
        if peak.sceneScore >= 0.58 { reasons.append("scene") }
        if reasons.isEmpty {
            let strongest = [
                ("sound", peak.audioScore),
                ("motion", peak.motionScore),
                ("scene", peak.sceneScore),
            ].max { $0.1 < $1.1 }
            reasons = [strongest?.0 ?? "moment"]
        }

        return Highlight(
            id: UUID(),
            sourceID: source.id,
            sourceIndex: sourceIndex,
            sourceName: source.name,
            start: start,
            end: end,
            peak: peak.sample.time,
            score: metrics.score,
            peakScore: metrics.peakScore,
            sequenceStrength: metrics.strength,
            cropX: cropX,
            framingOverride: nil,
            reasons: reasons
        )
    }
}
