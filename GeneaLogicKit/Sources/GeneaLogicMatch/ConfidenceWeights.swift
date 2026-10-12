import GeneaLogicModel

/// The two Genealogical Proof Standard weights an `EvidenceLink` carries (§4.6).
///
/// These do **not** score the match. They score the *source*: how much a claim from
/// this document is worth, independent of how well the names line up. The roll-up
/// then uses them to discount a match, which is why a perfect name agreement on a
/// compiled online tree ends up below a good agreement on a parish register.
public enum ConfidenceWeights {

    // MARK: - Source authority

    /// 0–100 from the record's two orthogonal authority axes: **what genre of record
    /// is this** (`SourceAuthorityTier`) and **how far is it from the event**
    /// (`SourceDerivation`, added in slice 44h to complete the GPS model).
    ///
    /// Both are optional on `Artifact`, and **absent means unstated, never a default
    /// good value.** An untiered record gets a middling base rather than a generous
    /// one, and an unstated derivation takes a slight discount rather than the
    /// `original` multiplier — a researcher who hasn't said where a document sits must
    /// not have "it's an original" assumed on their behalf.
    public static func sourceAuthorityWeight(
        tier: SourceAuthorityTier?,
        derivation: SourceDerivation?
    ) -> Int {
        Scoring.clamped(Double(tierBase(tier)) * derivationMultiplier(derivation))
    }

    /// The genre base. Vital and church records are the registers themselves; a
    /// government record is an authority's contemporaneous record of the subject's own
    /// statement, a notch under `vital` because it registers an *application* rather
    /// than the event it reports; a census is a good but decennial snapshot taken by a
    /// stranger at the door; a stone is contemporaneous with the death and
    /// family-erected — strong for the death, weak for the birth on it, so it sits
    /// between `census` and `bible`; a compiled tree is somebody's conclusion, not
    /// evidence, and is scored accordingly.
    private static func tierBase(_ tier: SourceAuthorityTier?) -> Int {
        switch tier {
        case .vital: 90
        case .church: 85
        case .government: 80
        case .census: 65
        case .monument: 60
        case .bible: 55
        case .newspaper: 45
        case .compiled: 25
        // An unrecognized tier is a real value this build hasn't heard of, not an
        // error — the open-vocabulary contract. Treat it as unstated.
        case .unknown, nil: 40
        }
    }

    /// The derivation discount. A transcription of a register is not the register: an
    /// index entry has already passed through one reader's eyes and one typist's
    /// fingers, and an authored work through an argument.
    private static func derivationMultiplier(_ derivation: SourceDerivation?) -> Double {
        switch derivation {
        case .original: 1.0
        case .derivative: 0.8
        case .authored: 0.6
        case .unknown, nil: 0.9
        }
    }

    // MARK: - Information quality

    /// 0–100 from the information quality of the facts that actually drove the match.
    ///
    /// The GPS's per-*field* axis: a death certificate is primary for the death it
    /// records and secondary for the birth the informant recalled. Slice 44h made that
    /// expressible in two levels — a mention-wide default with a per-`RecordedFact`
    /// override — and `RecordedFact.effectiveInformationQuality(within:)` is the one
    /// place the "absent means inherit" rule is decoded, so this reads through it
    /// rather than re-deriving it.
    ///
    /// **The worst quality among the facts used wins**, not the average. A match
    /// resting partly on a secondhand birth date is only as good as that birth date;
    /// averaging would let a primary fact launder a secondary one sitting beside it.
    /// With no facts in play the mention's own default stands — the identification
    /// rests on the name alone, and the mention's quality is the honest statement of
    /// how close the informant stood.
    public static func informationQualityWeight(
        factsUsed: [RecordedFact],
        within mention: MentionMatchView
    ) -> Int {
        let qualities = factsUsed.map {
            $0.effectiveInformationQuality(within: mentionRecord(mention))
        }
        let effective = qualities.min(by: { rank($0) < rank($1) }) ?? mention.informationQuality
        return qualityWeight(effective)
    }

    private static func qualityWeight(_ quality: InformationQuality) -> Int {
        switch quality {
        case .primary: 100
        case .secondary: 55
        // Not a middle value: "we don't know how close the informant was" is weaker
        // evidence than "we know they were secondhand", because it might be worse.
        case .undetermined: 40
        }
    }

    /// Ordering for "worst quality wins".
    private static func rank(_ quality: InformationQuality) -> Int {
        switch quality {
        case .undetermined: 0
        case .secondary: 1
        case .primary: 2
        }
    }

    /// `RecordedFact.effectiveInformationQuality(within:)` is defined against a real
    /// `PersonMention`, and reimplementing its `?? mention.informationQuality` fallback
    /// here would be a second copy of a format-level rule — exactly the drift slice 44c
    /// existed to end. So the view is projected back into the shape that rule takes.
    /// Only `informationQuality` is read; the rest is filler.
    private static func mentionRecord(_ view: MentionMatchView) -> PersonMention {
        PersonMention(
            localRef: view.localRef,
            nameAsRecorded: view.nameAsRecorded,
            role: view.role,
            informationQuality: view.informationQuality)
    }
}
