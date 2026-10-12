import GeneaLogicModel

/// Entity resolution: does this **mention in a document** name this **concluded
/// person**?
///
/// The matcher **suggests and never commits** (§4.6). It returns a decomposed
/// ``ScoredMatch``; nothing here writes, and nothing here decides. Turning a score
/// into an `EvidenceLink` requires a human, and that path is slice 45c's.
///
/// ## Reading the output
///
/// `aggregateConfidence` is a sort key. The **breakdown is the answer** — it is what
/// lets a reviewer see "strong name and spouse agreement, birth year off by three,
/// place matched to the town" instead of an unexaminable "71%". Every dimension is
/// optional except the name, and a `nil` dimension means *not assessed* rather than
/// *assessed and failed*, because the documents this reads are usually silent about
/// most things.
public enum Matcher {

    /// What goes in `Provenance.tool` on a link whose breakdown this matcher computed.
    ///
    /// A stored breakdown is only meaningful if you know what produced it, and "the
    /// matcher" is not an answer once the scoring has moved on. **Bump the version
    /// whenever a change makes old breakdowns non-comparable with new ones** — a
    /// re-weighted roll-up, a new dimension, a different keyer — so a link written last
    /// year can be told apart from one written today without rescoring it to find out.
    /// A refactor that provably cannot move a score leaves it alone.
    public static let toolIdentifier = "genealogic-matcher/6"

    /// Scores one mention against one candidate person.
    ///
    /// Pure and deterministic: the same two views always produce the same integers, on
    /// every platform, which is what makes a stored breakdown meaningful months later.
    /// The vocabulary is part of "the same inputs" — see ``PlaceVocabulary``, and note
    /// that a *changed archive* can therefore change this score, which is the point of
    /// it and the reason it is passed rather than defaulted.
    ///
    /// - Parameter places: What the archive's own place strings prove about place
    ///   depth. **Deliberately without a default**: it moves scores, so a new call site
    ///   should have to decide what it is passing rather than inherit an empty one and
    ///   quietly disagree with every other entry point.
    public static func score(
        _ mention: MentionMatchView,
        against person: PersonMatchView,
        places: PlaceVocabulary
    ) -> ScoredMatch {
        let (name, algorithm) = NameMatching.score(
            recorded: mention.nameAsRecorded,
            script: mention.nameScript,
            against: person.names)

        let recordedBirth = mention.facts.first { $0.type == .birth }
        let concludedBirth = person.facts.first { $0.type == .birth }

        let birthYear = DateMatching.scoreBirthYear(
            recorded: DateMatching.firstYear(in: [recordedBirth?.date]),
            concluded: DateMatching.firstYear(in: [concludedBirth?.date]))
        let birthPlace = PlaceMatching.score(
            recorded: recordedBirth?.place, concluded: concludedBirth?.place, places: places)

        let spouseName = relational(
            mention: mention, role: .spouse, against: person.partnerNames)
        let parents = relational(
            mention: mention, role: .parent, against: person.parentNames)

        let conflicts = detectConflicts(
            mention: mention, person: person,
            birthYear: birthYear, birthPlace: birthPlace,
            recordedBirth: recordedBirth, concludedBirth: concludedBirth)

        let breakdown = MatchBreakdown(
            name: name,
            nameAlgo: algorithm,
            birthYear: birthYear,
            birthPlace: birthPlace,
            spouseName: spouseName,
            parents: parents,
            conflicts: conflicts)

        // Only facts that actually contributed weigh on information quality — a
        // secondhand residence nobody scored must not discount a match it took no
        // part in.
        var factsUsed: [RecordedFact] = []
        if birthYear != nil || birthPlace != nil, let recordedBirth {
            factsUsed.append(recordedBirth)
        }

        let sourceAuthority = ConfidenceWeights.sourceAuthorityWeight(
            tier: mention.sourceTier, derivation: mention.sourceDerivation)
        let informationQuality = ConfidenceWeights.informationQualityWeight(
            factsUsed: factsUsed, within: mention)

        return ScoredMatch(
            breakdown: breakdown,
            sourceAuthorityWeight: sourceAuthority,
            informationQualityWeight: informationQuality,
            aggregateConfidence: aggregate(
                breakdown: breakdown,
                sourceAuthorityWeight: sourceAuthority,
                informationQualityWeight: informationQuality))
    }

    // MARK: - Relational dimensions

    /// Scores the `spouseName` / `parents` dimensions from the record's **other**
    /// mentions.
    ///
    /// §4.6 wants relational evidence — the strongest confirmation that a "Marcus
    /// Hanner" in a marriage register is *your* Marcus Hanner is that the bride beside
    /// him is your Fay. Which co-mentions stand in the relation is answered by the
    /// record's stated edges where it has them and by its `PersonRole` tags where it
    /// doesn't; see ``coMentions(standingIn:to:)``.
    ///
    /// Returns `nil` unless **both** sides have something to compare: a record with no
    /// spouse named, or a person with no known partner, has not failed this dimension.
    private static func relational(
        mention: MentionMatchView,
        role: PersonRole,
        against candidates: [PersonName]
    ) -> MatchDimension? {
        let recorded = coMentions(standingIn: role, to: mention)
        guard !recorded.isEmpty, !candidates.isEmpty else { return nil }

        var best = MatchDimension(kind: .none, score: 0)
        for coMention in recorded {
            let (dimension, _) = NameMatching.score(
                recorded: coMention.nameAsRecorded,
                script: coMention.nameScript,
                against: candidates)
            if dimension.score > best.score { best = dimension }
        }
        return best
    }

    /// The co-mentions the record actually places in `relation` **to the mention being
    /// scored** — the record's own stated edges when it has any, and otherwise the
    /// vantage-point rule (slice 45g).
    ///
    /// ## Stated edges win (slice 45k)
    ///
    /// A `MentionRelationship` says outright what the star inference below could only
    /// approximate, so where the record places **this mention** in the relation being
    /// scored, those edges *are* the answer and the inference is not consulted. That is
    /// the point: on a marriage register stating all four parent edges, each spouse now
    /// scores against **their own** two parents instead of best-of all four.
    ///
    /// The preference is per mention and per relation type — never per record. A record
    /// that states its parent edges has not denied that its two `spouse` mentions are
    /// married, and one that states the bride's parents has not denied that the groom
    /// has any; reading either silence as denial would mean adding information to a
    /// record could *lose* a dimension it used to score, punishing exactly the user who
    /// did the work. See ``statedCoMentions(standingIn:to:)``.
    ///
    /// ## Otherwise: the star (slice 45g)
    ///
    /// `PersonRole` states a person's role *in the document*, not their role relative
    /// to whichever mention is being scored: on a death certificate `spouse` means
    /// *spouse of the deceased*. So an edge-less record reads as a **star around its
    /// centre**, never as a graph — see ``principalRole(on:)`` for what the centre is.
    /// Scoring a principal, every role is already relative to it. Scoring anyone else,
    /// the only relation the document states is that mention's own tie to the centre —
    /// and every other pairing (parent ↔ spouse, parent ↔ parent) is **unstated**, so it
    /// must go unassessed rather than score zero.
    ///
    /// Reading it as a graph is what made the deceased's father draw a `spouseName: 0`
    /// from the *deceased's* widow: a dimension that never should have existed, costing
    /// a correct pair 18 points. Inferring the sibling and in-law edges instead would
    /// invent relationships the record never asserted.
    private static func coMentions(
        standingIn relation: PersonRole, to mention: MentionMatchView
    ) -> [CoMention] {
        if let stated = statedCoMentions(standingIn: relation, to: mention) { return stated }

        guard let principal = principalRole(on: mention) else { return [] }

        if mention.role == principal {
            // A principal: every other role on the record is stated relative to it.
            return mention.coMentions.filter { $0.role == relation }
        }

        // A satellite: the only relation the document states is its own tie to the
        // record's principals, which is its role seen from the other end.
        guard inverse(of: mention.role) == relation else { return [] }
        return mention.coMentions.filter { $0.role == principal }
    }

    /// The co-mentions the record's **own stated edges** place in `relation` to the
    /// mention being scored, or `nil` when the record states nothing about *this
    /// mention* in that relation and the star inference should answer instead (45k).
    ///
    /// **Scoped to the mention, not to the record** — the correction that matters here.
    /// Asking "does this record state any parent edge at all?" turns the inference off
    /// for *everyone* the moment one edge exists, so on a marriage register where only
    /// the bride's parents have been stated, the **groom** loses a `parents` dimension he
    /// scored before: partway through cataloguing, adding information takes a match
    /// apart. A record that says who the bride's parents are has said nothing whatever
    /// about the groom's, and §6.1 forbids reading that silence as denial.
    ///
    /// So there is no `[]` case: either the record places this mention in this relation —
    /// and then those edges are the whole answer, which is what makes each spouse score
    /// against *their own* parents once all four are stated — or it doesn't, and the
    /// roles answer as they always did.
    ///
    /// Only `parent` and `spouse` map onto an edge type, because only those two have a
    /// dimension to score (`PersonMatchView` carries partners and parents, not children).
    /// A record stating a `parent-child` edge in which this mention is the **parent** has
    /// said something true and useful that nothing here can yet compare against; it goes
    /// unassessed, exactly as `inverse(of:)` already does for the same case.
    private static func statedCoMentions(
        standingIn relation: PersonRole, to mention: MentionMatchView
    ) -> [CoMention]? {
        let edges = mention.mentionRelationships
        let me = mention.localRef
        let refs: Set<String>

        switch relation {
        case .parent:
            // `childRef` is nil on any other edge type, so this is already type-scoped —
            // and it is the §4.5 direction, read through the accessor rather than by hand.
            let stated = edges.filter { $0.childRef == me }
            guard !stated.isEmpty else { return nil }
            refs = Set(stated.compactMap(\.parentRef))
        case .spouse:
            // Symmetric: whichever end this mention sits at, the partner is the other.
            let stated = edges.filter { $0.type == .couple && $0.involves(me) }
            guard !stated.isEmpty else { return nil }
            refs = Set(stated.compactMap { $0.other(from: me) })
        default:
            return nil
        }

        return mention.coMentions.filter { refs.contains($0.localRef) }
    }

    /// The role held by the mentions the record is **about** — its centre.
    ///
    /// Usually `subject`. But a marriage register has no subject at all: it names a
    /// **couple**, both tagged `spouse`, and the parents beside them are the parents
    /// *of that couple*. Both records of that shape in the corpus are exactly this, so
    /// a rule that insisted on a `subject` would throw away the strongest relational
    /// evidence the archive holds — a marriage record is the couple document.
    ///
    /// Returns `nil` when the record has no centre: two witnesses to a deed are
    /// related to each other by nothing the document says.
    private static func principalRole(on mention: MentionMatchView) -> PersonRole? {
        principalRole(among: [mention.role] + mention.coMentions.map(\.role))
    }

    /// The same question asked of a whole record's roles rather than from one mention's
    /// vantage point — **public because slice 45l's derivation asks it too**.
    ///
    /// Promoting a role-inferred relationship into `conclusions/` and scoring a relational
    /// dimension are different acts, but they must agree about where the record's centre
    /// *is*, or the app would offer a conclusion the matcher's reasoning never supported.
    /// One rule, two callers. (45l is deliberately stricter about what it does with the
    /// answer — it refuses to conclude anything where the centre is more than one person —
    /// but that is a rule about concluding, not about the centre.)
    public static func principalRole(among roles: [PersonRole]) -> PersonRole? {
        if roles.contains(.subject) { return .subject }
        if roles.contains(.spouse) { return .spouse }
        return nil
    }

    /// The relation the record's **subject** stands in to a mention carrying `role` —
    /// the mention's own tie to the subject, seen from the other end.
    ///
    /// `spouse` inverts to itself, which is what lets a widow's own mention finally
    /// draw a `spouseName` from the deceased beside her. `parent` inverts to *child*,
    /// which `PersonRole` has no case for and no dimension reads: a parent's tie to the
    /// subject **is** stated by the record, it simply isn't scorable against anything
    /// `PersonMatchView` carries, so it goes unassessed. Every other role — witness,
    /// informant, godparent, registrar, an unknown one — states no family relation at
    /// all.
    private static func inverse(of role: PersonRole) -> PersonRole? {
        switch role {
        case .spouse: .spouse
        default: nil
        }
    }

    // MARK: - Conflicts

    /// Disagreements that must not be averaged away (§4.6).
    ///
    /// A conflict is not a low score. Two records that agree on a name and disagree on
    /// a birth year by ten are *more* suspicious than two that share only a name —
    /// the agreement is what makes the disagreement matter. So these are collected
    /// separately, drive a sharp penalty in the roll-up, and are written as sentences a
    /// reviewer can act on rather than as codes.
    private static func detectConflicts(
        mention: MentionMatchView,
        person: PersonMatchView,
        birthYear: MatchDimension?,
        birthPlace: MatchDimension?,
        recordedBirth: RecordedFact?,
        concludedBirth: PersonFact?
    ) -> [String] {
        var conflicts: [String] = []

        // A birth-year gap the era's tolerance can't absorb.
        if let birthYear, birthYear.kind == .none, let delta = birthYear.delta,
            let recorded = DateMatching.firstYear(in: [recordedBirth?.date]),
            let concluded = DateMatching.firstYear(in: [concludedBirth?.date])
        {
            let allowed = DateMatching.tolerance(forYear: min(recorded, concluded))
            conflicts.append(
                "birthYear: record says \(recorded), conclusion says \(concluded) "
                    + "— \(delta) years apart, tolerance \(allowed)")
        }

        // Birth places that share nothing, not even a country.
        if let birthPlace, birthPlace.kind == .none,
            let recorded = recordedBirth?.place, let concluded = concludedBirth?.place
        {
            conflicts.append(
                "birthPlace: record says \"\(recorded)\", conclusion says \"\(concluded)\" "
                    + "— no shared region")
        }

        // A death before a birth is not a weak match, it is a different person.
        if let recordedDeath = DateMatching.firstYear(
            in: mention.facts.filter { $0.type == .death }.map(\.date)),
            let concludedBirthYear = DateMatching.firstYear(in: [concludedBirth?.date]),
            recordedDeath < concludedBirthYear
        {
            conflicts.append(
                "lifespan: record's death \(recordedDeath) precedes the conclusion's "
                    + "birth \(concludedBirthYear)")
        }

        return conflicts
    }

    // MARK: - Roll-up

    /// Folds the breakdown and the two GPS weights into one 0–100 sort key.
    ///
    /// Four stages, in this order and for these reasons:
    ///
    /// 1. **A weighted mean over the dimensions that were assessed.** Name carries the
    ///    most because it is the only dimension every record supplies. Absent
    ///    dimensions are dropped and the remaining weights renormalized, so a sparse
    ///    record is scored on what it says rather than punished for its silences.
    /// 2. **A source discount**, never a source multiplier. The GPS weights scale the
    ///    result into `0.6...1.0` rather than `0...1`: a parish register cannot invent
    ///    an agreement that isn't there, and a compiled tree with a perfect name,
    ///    birth year, place and spouse match is still telling you something. Letting
    ///    the weights run to zero would silently discard real matches from weak
    ///    sources, which is a research decision the matcher has no business making on
    ///    a researcher's behalf.
    /// 3. **A corroboration factor**, because stage 1 cannot express breadth. A mean
    ///    over one perfect dimension and a mean over four perfect dimensions are both
    ///    100, so without this a bare name match ties with a match confirmed by birth
    ///    year, birth place *and* spouse — which would make the queue's top rung
    ///    meaningless exactly where it matters most. An uncorroborated match is held
    ///    below a corroborated one, which is also the GPS's own position: a single
    ///    agreeing detail is a hypothesis, and independent agreement is what makes it
    ///    a conclusion.
    /// 4. **A sharp conflict penalty**, applied last so it cannot be averaged away.
    private static func aggregate(
        breakdown: MatchBreakdown,
        sourceAuthorityWeight: Int,
        informationQualityWeight: Int
    ) -> Int {
        let dimensions: [(MatchDimension?, Double)] = [
            (breakdown.name, nameWeight),
            (breakdown.birthYear, birthYearWeight),
            (breakdown.birthPlace, birthPlaceWeight),
            (scoring(breakdown.spouseName), spouseNameWeight),
            (scoring(breakdown.parents), parentsWeight),
        ]

        var total = 0.0
        var weightSum = 0.0
        for (dimension, weight) in dimensions {
            guard let dimension else { continue }
            total += Double(dimension.score) * weight
            weightSum += weight
        }
        guard weightSum > 0 else { return 0 }
        let base = total / weightSum

        let evidence = Double(sourceAuthorityWeight + informationQualityWeight) / 200.0
        let discounted = base * (sourceFloor + (1.0 - sourceFloor) * evidence)

        // Only dimensions that actually *agreed* corroborate. A birth year that was
        // assessed and disagreed is not breadth of evidence — it is the opposite, and
        // it is already being handled as a conflict.
        let corroborating = dimensions.dropFirst()
            .compactMap(\.0)
            .filter { $0.score >= corroborationThreshold }
            .count
        let breadth = min(Double(corroborating), fullCorroboration) / fullCorroboration
        let corroborated =
            discounted * (uncorroboratedFactor + (1.0 - uncorroboratedFactor) * breadth)

        let penalized = breakdown.conflicts.isEmpty ? corroborated : corroborated * conflictPenalty
        return Scoring.clamped(penalized)
    }

    /// Whether a relational dimension moves the roll-up (slice 45g).
    ///
    /// **Relational evidence is positive-only: it corroborates, it never penalizes.**
    /// A `spouseName` of `none` is reported — the record did name a spouse, and that
    /// they don't agree is a lead a reviewer wants — but it is not scored, because
    /// a name disagreement between two *true* partners is the common case, not the
    /// suspicious one: maiden against married, Yiddish against Americanized, a clerk's
    /// transcription against another clerk's. This is the classic record-linkage
    /// asymmetry (Fellegi–Sunter): a field's *disagreement* weight is governed by how
    /// often genuinely-matching pairs disagree on it, and for a name read across
    /// records that rate is high enough to make the penalty worthless.
    ///
    /// The concrete failure it prevents: recording a true marriage dropped a correct
    /// pair 73 → 55, because `spouseName` went from unassessed to zero. A conclusion
    /// the researcher got *right* made the matcher less confident — corroboration
    /// running backwards.
    ///
    /// The two fact dimensions keep their zeros because each justifies itself with a
    /// conflict sentence a reviewer can act on; a relational zero explained nothing and
    /// dragged the mean silently.
    ///
    /// Public because the surfaces that draw a breakdown must be able to say which
    /// dimensions the number came from, rather than each re-deriving the rule.
    public static func counts(relational dimension: MatchDimension) -> Bool {
        dimension.kind != .none
    }

    /// The relational dimension as the roll-up sees it: absent when it didn't agree.
    private static func scoring(_ dimension: MatchDimension?) -> MatchDimension? {
        guard let dimension, counts(relational: dimension) else { return nil }
        return dimension
    }

    private static let nameWeight = 0.45
    private static let birthYearWeight = 0.20
    private static let spouseNameWeight = 0.15
    private static let birthPlaceWeight = 0.10
    private static let parentsWeight = 0.10

    /// The lowest a perfect match can be discounted to by a weak source.
    private static let sourceFloor = 0.6

    /// What an entirely uncorroborated match — a name and nothing else — retains.
    /// Deliberately mild: a name-only agreement on a strong source is still a good
    /// suggestion, it just should not outrank one the record corroborates.
    private static let uncorroboratedFactor = 0.88

    /// How many agreeing non-name dimensions count as fully corroborated. Three is
    /// the practical ceiling: a record naming a birth year, a birth place and a
    /// spouse has said everything this scorer knows how to read.
    private static let fullCorroboration = 3.0

    /// How well a dimension must score to count as corroborating rather than merely
    /// assessed.
    private static let corroborationThreshold = 60

    /// What a conflict costs. Deliberately severe: the point is to push a conflicted
    /// pair out of the top of a review queue, not to nudge it.
    private static let conflictPenalty = 0.4
}
