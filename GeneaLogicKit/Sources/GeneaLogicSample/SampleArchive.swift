import Foundation
import GeneaLogicArchive
import GeneaLogicModel

/// The sample archive (slice 74b): one invented family, written through the public API,
/// so a stranger has something to open and every part of the app has something to show.
///
/// The family is slice 74's cast. Over nine documents and four generations, the
/// Sternfelds of Korostyshev, the Feldbergs of Kutno and Marcus Hanner of Rypin end up
/// in Brooklyn. Most of the evidence is linked; some is left for the reader to review:
///
/// - eleven names are left unlinked, so the matcher has suggestions to explain: all six
///   lines of the 1920 census (the household as *Honner*), the wife and children on the
///   naturalization, and the father and informant on the death certificate;
/// - *Markus Hanaur*, entered from the ship manifest, is the same man as Marcus Hanner,
///   so the duplicates lane has a pair;
/// - the death certificate links Sidney and his mother, but no relationship joins them,
///   so the record suggests one;
/// - the naturalization is linked to Marcus but is not one of his facts yet.
///
/// Each document carries a page image rendered by `scripts/render-sample-pages.swift`.
/// The pages and the records here must say the same thing.
public enum SampleArchive {
    /// The archive's name, as `Archive.create(at:name:)` records it.
    public static let name = "The Hanner Family (sample)"

    /// The package name the app and the CLI suggest.
    public static let fileName = "Hanner Family Sample.genea"

    /// Builds the sample at `url`, which must not exist.
    ///
    /// The archive is built beside `url` under a hidden name and renamed into place, so
    /// an interrupted build never leaves a half-built archive where the app would open it.
    /// Throws `alreadyExists` whenever something is at `url`, including when it arrived
    /// during the build (two windows asking at once): the caller can open that one.
    public static func build(at url: URL) throws {
        try build(at: url, beforeMove: {})
    }

    /// `build(at:)` with a hook between building and renaming, for the tests to fail or
    /// race the rename.
    static func build(at url: URL, beforeMove: () throws -> Void) throws {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: url.path) else {
            throw SampleArchiveError.alreadyExists(url)
        }
        sweepAbandonedBuilds(beside: url)
        let staging = url.deletingLastPathComponent()
            .appendingPathComponent(stagingPrefix(for: url) + UUID().uuidString)
        do {
            try populate(at: staging)
            try beforeMove()
            try fileManager.moveItem(at: staging, to: url)
        } catch {
            try? fileManager.removeItem(at: staging)
            if fileManager.fileExists(atPath: url.path) {
                throw SampleArchiveError.alreadyExists(url)
            }
            throw error
        }
    }

    /// How long a staging folder can sit unrenamed before it counts as abandoned. A build
    /// takes about half a second, so an hour is never a build still running.
    static let abandonedAfter: TimeInterval = 60 * 60

    private static func stagingPrefix(for url: URL) -> String {
        ".\(url.lastPathComponent).building-"
    }

    /// Removes the staging folders of builds that were killed before they could clean up
    /// (a quit mid-build, a Ctrl-C). They are hidden, so nobody else would.
    private static func sweepAbandonedBuilds(beside url: URL) {
        let fileManager = FileManager.default
        let folder = url.deletingLastPathComponent()
        let prefix = stagingPrefix(for: url)
        let cutoff = Date().addingTimeInterval(-abandonedAfter)
        for name in (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        where name.hasPrefix(prefix) {
            let candidate = folder.appendingPathComponent(name)
            let modified =
                (try? fileManager.attributesOfItem(atPath: candidate.path))?[.modificationDate]
                as? Date
            if let modified, modified < cutoff {
                try? fileManager.removeItem(at: candidate)
            }
        }
    }

    /// Writes the whole sample. The `Archive` is released when this returns, before the
    /// rename.
    private static func populate(at url: URL) throws {
        let archive = try Archive.create(at: url, name: name)
        var writer = Writer(archive: archive)
        try writer.writeEverything()
    }
}

/// Why a sample could not be built.
public enum SampleArchiveError: Error, CustomStringConvertible, Equatable {
    case alreadyExists(URL)
    case missingPage(String)
    /// A fact cites a document's mention that the sample never linked: a mistake in the
    /// sample's own source.
    case unknownLink(String)

    public var description: String {
        switch self {
        case .alreadyExists(let url):
            "Something already exists at \(url.path); the sample is built only where nothing is."
        case .missingPage(let name):
            "The sample page \(name) is missing from this build."
        case .unknownLink(let key):
            "The sample cites \(key), which it never linked."
        }
    }
}

// MARK: - The family

private let rypin = "Rypin, Poland"
private let kutno = "Kutno, Poland"
private let korostyshev = "Korostyshev, Russia"
private let brooklyn = "Brooklyn, Kings, New York"

private struct Writer {
    let archive: Archive

    /// The links written so far, by document and mention, for the facts that cite them.
    var links: [String: EvidenceLinkID] = [:]

    init(archive: Archive) { self.archive = archive }

    mutating func writeEverything() throws {
        // People first, so the documents can be linked to them as they are added.
        let berek = try person(.birth, "Berek", "Sternfeld")
        let sura = try person(.birth, "Sura", "Sternfeld")
        let gussie = try person(
            names: [
                PersonName.deriving(type: .birth, given: "Gitla", surname: "Sternfeld"),
                PersonName.deriving(
                    type: .alsoKnownAs, given: "Гитля", surname: "Штернфельд", language: "ru",
                    script: "Cyrl"),
                PersonName.deriving(type: .married, given: "Gussie", surname: "Feldberg"),
            ])
        let solomon = try person(
            names: [
                PersonName.deriving(type: .birth, given: "Szlama", surname: "Feldberg"),
                PersonName.deriving(type: .alsoKnownAs, given: "Solomon", surname: "Feldberg"),
            ])
        let fay = try person(
            names: [
                PersonName.deriving(type: .birth, given: "Fay", surname: "Feldberg"),
                PersonName.deriving(type: .married, given: "Fay", surname: "Hanner"),
            ])
        let sidney = try person(
            names: [
                PersonName.deriving(type: .birth, given: "Zelig", surname: "Feldberg"),
                PersonName.deriving(type: .alsoKnownAs, given: "Sidney", surname: "Feldberg"),
            ])
        let marcus = try person(
            names: [
                PersonName.deriving(type: .birth, given: "Marcus", surname: "Hanner"),
                PersonName.deriving(
                    type: .alsoKnownAs, given: "מאיר", surname: nil, language: "he",
                    script: "Hebr"),
            ])
        let isaac = try person(.birth, "Isaac", "Hanner")
        let esther = try person(
            names: [
                PersonName.deriving(type: .birth, given: "Esther", surname: "Kahn"),
                PersonName.deriving(type: .married, given: "Esther", surname: "Hanner"),
            ])
        let irving = try person(.birth, "Irving", "Hanner")
        let rose = try person(.birth, "Rose", "Hanner")
        // The same man as Marcus, entered from the manifest before anyone noticed.
        let markus = try person(.birth, "Markus", "Hanaur")

        try documents(
            People(
                berek: berek, sura: sura, gussie: gussie, solomon: solomon, fay: fay,
                sidney: sidney, isaac: isaac, esther: esther, marcus: marcus, irving: irving,
                rose: rose, markus: markus))

        // Facts, each citing the links that support it.
        try facts(
            gussie,
            PersonFact(
                type: .birth, date: "1862-03-03", place: korostyshev,
                supportedByLinks: try cite("birth/p3")),
            PersonFact(type: .immigration, date: "1907", place: "New York"))
        try facts(
            solomon, PersonFact(type: .birth, date: "1858~", place: kutno),
            PersonFact(type: .immigration, date: "1907", place: "New York"),
            PersonFact(type: .death, date: "1931", place: brooklyn))
        try facts(
            fay,
            PersonFact(
                type: .birth, date: "1889~", place: kutno,
                supportedByLinks: try cite("marriage/p2", "census1915/p2")),
            PersonFact(type: .death, date: "1960", place: brooklyn))
        try facts(
            sidney,
            PersonFact(
                type: .birth, date: "1892~", place: kutno, supportedByLinks: try cite("death/p1")),
            PersonFact(
                type: .death, date: "1938-02-09", place: brooklyn,
                supportedByLinks: try cite("death/p1")))
        try facts(
            marcus,
            PersonFact(
                type: .birth, date: "1884-03-02", place: rypin,
                supportedByLinks: try cite("naturalization/p1", "gravestone/p1")),
            PersonFact(
                type: .immigration, date: "1906-05-14", place: "New York",
                supportedByLinks: try cite("naturalization/p1")),
            PersonFact(type: .occupation, value: "tailor", supportedByLinks: try cite("census1915/p1")),
            PersonFact(
                type: .death, date: "1951-01-17", place: brooklyn,
                supportedByLinks: try cite("gravestone/p1")))
        try facts(
            irving,
            PersonFact(
                type: .birth, date: "1912~", place: brooklyn,
                supportedByLinks: try cite("census1915/p3")))
        try facts(
            rose,
            PersonFact(
                type: .birth, date: "1915~", place: brooklyn,
                supportedByLinks: try cite("census1915/p4")))
        try facts(
            markus,
            PersonFact(
                type: .birth, date: "1884~", place: rypin, supportedByLinks: try cite("manifest/p1")),
            PersonFact(
                type: .immigration, date: "1906-05-14", place: "New York",
                supportedByLinks: try cite("manifest/p1")))

        // The tree. Sidney's mother is left for the death certificate to suggest.
        try couple(berek, sura)
        try parent(berek, of: gussie, citing: "birth/p1")
        try parent(sura, of: gussie, citing: "birth/p2")
        try couple(solomon, gussie)
        try parent(solomon, of: fay, citing: "marriage/p3")
        try parent(gussie, of: fay, citing: "marriage/p4")
        try parent(solomon, of: sidney)
        try couple(
            marcus, fay,
            PersonFact(
                type: .marriage, date: "1910-06-12", place: brooklyn,
                supportedByLinks: try cite("marriage/p1", "marriage/p2")))
        try couple(isaac, esther)
        try parent(isaac, of: marcus, citing: "marriage/p5")
        try parent(esther, of: marcus, citing: "marriage/p6")
        try parent(marcus, of: irving, citing: "census1915/p1")
        try parent(fay, of: irving, citing: "census1915/p2")
        try parent(marcus, of: rose, citing: "census1915/p1")
        try parent(fay, of: rose, citing: "census1915/p2")
    }

    // MARK: The documents

    /// Everyone the documents are linked to.
    struct People {
        let berek, sura, gussie, solomon, fay, sidney, isaac, esther, marcus, irving, rose,
            markus: Person
    }

    mutating func documents(_ people: People) throws {
        try document(
            "birth", page: "1862-sternfeld-birth.jpg",
            ArtifactDraft(
                title: "Birth of Gitla Sternfeld, Korostyshev, 1862",
                mediaType: .image, sourceAuthorityTier: .vital, sourceDerivation: .original,
                language: "ru",
                events: [Event(type: "Birth", date: "1862-03-03", location: korostyshev)],
                personsMentioned: [
                    mention(
                        "p1", "Берек Иосифов Штернфельд", .parent, language: "ru", script: "Cyrl"),
                    mention("p2", "Сура", .parent, language: "ru", script: "Cyrl"),
                    mention(
                        "p3", "Гитля",
                        facts: [
                            RecordedFact(type: .birth, date: "1862-03-03", place: "Коростышев")
                        ],
                        language: "ru", script: "Cyrl"),
                ],
                locations: [Location(asRecorded: "Коростышев", normalized: korostyshev)],
                transcript: """
                    Metrical book of Jewish births, Korostyshev, 1862, part one. Entry 47: \
                    born 3 March; the townsman Berek son of Iosif Sternfeld and his wife Sura; \
                    born at Korostyshev; the child is named Gitla.
                    """,
                tags: ["Sternfeld"]),
            relationships: [
                .init(type: .parentChild, person1Ref: "p1", person2Ref: "p3"),
                .init(type: .parentChild, person1Ref: "p2", person2Ref: "p3"),
                .init(type: .couple, person1Ref: "p1", person2Ref: "p2"),
            ],
            links: ["p1": people.berek, "p2": people.sura, "p3": people.gussie])

        try document(
            "manifest", page: "1906-ship-manifest.jpg",
            ArtifactDraft(
                title: "Passenger manifest, S.S. Weichsel, 1906",
                mediaType: .image, sourceAuthorityTier: .government,
                sourceDerivation: .original, language: "en",
                events: [Event(type: "Immigration", date: "1906-05-14", location: "New York")],
                personsMentioned: [
                    mention(
                        "p1", "Markus Hanaur", age: "22",
                        facts: [
                            RecordedFact(type: .immigration, date: "1906-05-14", place: "New York"),
                            RecordedFact(type: .residence, date: "1906", place: "Rypin"),
                            RecordedFact(type: .occupation, value: "tailor"),
                        ])
                ],
                locations: [
                    Location(asRecorded: "Hamburg"),
                    Location(asRecorded: "Rypin", normalized: rypin),
                ],
                transcript: """
                    Sailing from Hamburg April 28th, 1906, arriving at New York May 14th, 1906. \
                    Line 14: Hanaur, Markus; 22; male; tailor; Russia; last residence Rypin; \
                    final destination New York.
                    """,
                tags: ["Hanner", "immigration"]),
            links: ["p1": people.markus])

        try document(
            "marriage", page: "1910-marriage-certificate.jpg",
            ArtifactDraft(
                title: "Marriage of Marcus Hanner and Fay Feldberg, 1910",
                mediaType: .image, sourceAuthorityTier: .vital, sourceDerivation: .original,
                language: "en",
                events: [Event(type: "Marriage", date: "1910-06-12", location: brooklyn)],
                personsMentioned: [
                    mention(
                        "p1", "Marcus Hanner", age: "26",
                        facts: [
                            RecordedFact(type: .marriage, date: "1910-06-12", place: "Brooklyn"),
                            RecordedFact(
                                type: .birth, date: "1884~", place: "Rypin, Russia",
                                informationQuality: .secondary),
                        ]),
                    mention(
                        "p2", "Fay Feldberg", age: "21",
                        facts: [
                            RecordedFact(type: .marriage, date: "1910-06-12", place: "Brooklyn"),
                            RecordedFact(
                                type: .birth, date: "1889~", place: "Kutno, Russia",
                                informationQuality: .secondary),
                        ]),
                    mention("p3", "Solomon Feldberg", .parent, .secondary),
                    mention("p4", "Gussie Sternfeld", .parent, .secondary),
                    mention("p5", "Isaac Hanner", .parent, .secondary),
                    mention("p6", "Esther Kahn", .parent, .secondary),
                ],
                locations: [Location(asRecorded: "Brooklyn, N.Y.", normalized: brooklyn)],
                transcript: """
                    City of New York, Borough of Brooklyn. Certificate and Record of Marriage \
                    No. 11482. Groom: Marcus Hanner, 26, born Rypin, Russia; father Isaac \
                    Hanner, mother Esther Kahn. Bride: Fay Feldberg, 21, born Kutno, Russia; \
                    father Solomon Feldberg, mother Gussie Sternfeld. Married June 12th, 1910, \
                    at Brooklyn, by Rabbi A. Levy.
                    """,
                tags: ["Hanner", "Feldberg"]),
            relationships: [
                .init(type: .couple, person1Ref: "p1", person2Ref: "p2"),
                .init(type: .parentChild, person1Ref: "p3", person2Ref: "p2"),
                .init(type: .parentChild, person1Ref: "p4", person2Ref: "p2"),
                .init(type: .parentChild, person1Ref: "p5", person2Ref: "p1"),
                .init(type: .parentChild, person1Ref: "p6", person2Ref: "p1"),
            ],
            links: [
                "p1": people.marcus, "p2": people.fay, "p3": people.solomon, "p4": people.gussie, "p5": people.isaac, "p6": people.esther,
            ])

        try document(
            "census1915", page: "1915-state-census.jpg",
            ArtifactDraft(
                title: "New York State census, 1915 — Hanner household",
                mediaType: .image, sourceAuthorityTier: .census, sourceDerivation: .original,
                language: "en",
                events: [Event(type: "Census", date: "1915-06-01", location: brooklyn)],
                personsMentioned: [
                    censusMention("p1", "Marcus Hanner", age: "31", born: "1884~", in: "Russia"),
                    censusMention("p2", "Fay Hanner", age: "26", born: "1889~", in: "Russia"),
                    censusMention("p3", "Irving Hanner", age: "3", born: "1912~", in: "U.S."),
                    censusMention("p4", "Rose Hanner", age: "0", born: "1915", in: "U.S."),
                ],
                locations: [Location(asRecorded: "Siegel St., Brooklyn", normalized: brooklyn)],
                transcript: """
                    State of New York, census of 1915, Kings County, Assembly District 6, \
                    Election District 21, Block 12. Siegel St.: Hanner, Marcus, head, 31, \
                    Russia, 9 years in U.S., tailor; Fay, wife, 26, Russia, 8 years; Irving, \
                    son, 3, U.S.; Rose, daughter, 0, U.S.
                    """,
                tags: ["Hanner", "census"]),
            relationships: householdRelationships(head: "p1", wife: "p2", children: ["p3", "p4"]),
            links: ["p1": people.marcus, "p2": people.fay, "p3": people.irving, "p4": people.rose])

        // Nobody is linked to the 1920 census: it is what Review is for.
        try document(
            "census1920", page: "1920-federal-census.jpg",
            ArtifactDraft(
                title: "U.S. federal census, 1920 — Honner household",
                mediaType: .image, sourceAuthorityTier: .census, sourceDerivation: .original,
                language: "en",
                events: [Event(type: "Census", date: "1920-01-05", location: brooklyn)],
                personsMentioned: [
                    censusMention("p1", "Marcus Honner", age: "35", born: "1884~", in: "Poland"),
                    censusMention("p2", "Faye Honner", age: "30", born: "1889~", in: "Poland"),
                    censusMention("p3", "Irving Honner", age: "7", born: "1912~", in: "New York"),
                    censusMention("p4", "Rose Honner", age: "4", born: "1915~", in: "New York"),
                    censusMention(
                        "p5", "Solomon Feldberg", age: "61", born: "1858~", in: "Poland"),
                    censusMention("p6", "Gussie Feldberg", age: "57", born: "1862~", in: "Russia"),
                ],
                locations: [Location(asRecorded: "Brooklyn, Ward 3", normalized: brooklyn)],
                transcript: """
                    Fourteenth census of the United States: 1920. New York, Kings County, \
                    Brooklyn, Ward 3, enumeration district 412, enumerated January 5, 1920. \
                    Honner, Marcus, head, 35, Poland, immigrated 1906, tailor; Faye, wife, 30, \
                    Poland, 1907; Irving, son, 7, New York; Rose, daughter, 4, New York; \
                    Feldberg, Solomon, father-in-law, 61, Poland, 1907, presser; Gussie, \
                    mother-in-law, 57, Russia, 1907.
                    """,
                tags: ["Hanner", "Feldberg", "census"]),
            relationships: householdRelationships(head: "p1", wife: "p2", children: ["p3", "p4"])
                + [
                    .init(type: .couple, person1Ref: "p5", person2Ref: "p6"),
                    .init(type: .parentChild, person1Ref: "p5", person2Ref: "p2"),
                    .init(type: .parentChild, person1Ref: "p6", person2Ref: "p2"),
                ],
            links: [:])

        try document(
            "portrait", page: "1925-portrait-reverse.jpg",
            ArtifactDraft(
                title: "Family portrait, Brooklyn, 1925 (reverse)",
                mediaType: .image, sourceAuthorityTier: .compiled,
                sourceDerivation: .original, language: "en",
                events: [Event(type: "Photograph", date: "1925-06", location: brooklyn)],
                personsMentioned: [
                    mention("p1", "Marcus", .subject, .undetermined),
                    mention("p2", "Fay", .subject, .undetermined),
                    mention("p3", "Irving", .subject, .undetermined),
                    mention("p4", "Rose", .subject, .undetermined),
                ],
                transcript:
                    "Marcus, Fay, Irving & Rose. Brooklyn — June 1925. Studio stamp: Kessler Studio, Fine Portraits, Pitkin Avenue, Brooklyn.",
                tags: ["Hanner", "photograph"],
                notes:
                    "Only the reverse survives in this sample; the front would show the four of them."
            ),
            links: ["p1": people.marcus, "p2": people.fay, "p3": people.irving, "p4": people.rose])

        try document(
            "naturalization", page: "1927-naturalization.jpg",
            ArtifactDraft(
                title: "Naturalization of Marcus Hanner, 1927",
                mediaType: .image, sourceAuthorityTier: .government,
                sourceDerivation: .original, language: "en",
                events: [Event(type: "Naturalization", date: "1927-10-14", location: brooklyn)],
                personsMentioned: [
                    mention(
                        "p1", "Marcus Hanner", age: "43",
                        facts: [
                            RecordedFact(
                                type: .naturalization, date: "1927-10-14", place: "Brooklyn"),
                            RecordedFact(
                                type: .birth, date: "1884-03-02", place: "Rypin, Poland",
                                informationQuality: .secondary),
                            RecordedFact(type: .immigration, date: "1906-05-14", place: "New York"),
                        ]),
                    mention("p2", "Fay", .spouse, age: "38"),
                    mention("p3", "Irving", .unknown("child"), age: "15"),
                    mention("p4", "Rose", .unknown("child"), age: "12"),
                ],
                transcript: """
                    Certificate of Naturalization No. 2384117, petition volume 212, page 77. \
                    Marcus Hanner, age 43, born Rypin, Poland, March 2nd, 1884; arrived New \
                    York May 14th, 1906; residing in Brooklyn. Wife Fay, 38; minor children \
                    Irving, 15, and Rose, 12. Admitted a citizen on the 14th day of October, \
                    1927.
                    """,
                tags: ["Hanner"]),
            relationships: householdRelationships(head: "p1", wife: "p2", children: ["p3", "p4"]),
            links: ["p1": people.marcus])

        try document(
            "death", page: "1938-death-certificate.jpg",
            ArtifactDraft(
                title: "Death of Sidney Feldberg, 1938",
                mediaType: .image, sourceAuthorityTier: .vital, sourceDerivation: .original,
                language: "en",
                events: [Event(type: "Death", date: "1938-02-09", location: brooklyn)],
                personsMentioned: [
                    mention(
                        "p1", "Sidney Feldberg", age: "45",
                        facts: [
                            RecordedFact(type: .death, date: "1938-02-09", place: "Brooklyn"),
                            RecordedFact(
                                type: .birth, date: "1892~", place: "Kutno, Poland",
                                informationQuality: .secondary),
                            RecordedFact(type: .occupation, value: "furrier"),
                            RecordedFact(type: .burial, date: "1938-02-10"),
                        ]),
                    mention("p2", "Solomon Feldberg", .parent, .secondary),
                    mention("p3", "Gussie Sternfeld", .parent, .secondary),
                    mention("p4", "Fay Hanner", .informant),
                ],
                transcript: """
                    Department of Health of the City of New York, Certificate of Death, \
                    Borough of Brooklyn, No. 4102. Sidney Feldberg died February 9th, 1938, \
                    at Brooklyn, aged 45; born Kutno, Poland; furrier. Father Solomon \
                    Feldberg; mother Gussie Sternfeld. Informant: Mrs. Fay Hanner, sister. \
                    Buried February 10th, 1938.
                    """,
                tags: ["Feldberg"]),
            relationships: [
                .init(type: .parentChild, person1Ref: "p2", person2Ref: "p1"),
                .init(type: .parentChild, person1Ref: "p3", person2Ref: "p1"),
            ],
            links: ["p1": people.sidney, "p3": people.gussie])

        try document(
            "gravestone", page: "1951-gravestone.jpg",
            ArtifactDraft(
                title: "Gravestone of Marcus Hanner, 1951",
                mediaType: .image, sourceAuthorityTier: .monument,
                sourceDerivation: .original, language: "en",
                events: [Event(type: "Death", date: "1951-01-17")],
                personsMentioned: [
                    mention(
                        "p1", "Marcus Hanner",
                        facts: [
                            RecordedFact(
                                type: .birth, date: "1884-03-02", informationQuality: .secondary),
                            RecordedFact(type: .death, date: "1951-01-17"),
                        ]),
                    mention("p2", "יצחק", .parent, .secondary, language: "he", script: "Hebr"),
                ],
                transcript: """
                    פ״נ מאיר בן יצחק — Here lies Meir son of Yitzchak. MARCUS HANNER, \
                    MARCH 2, 1884 – JANUARY 17, 1951. BELOVED HUSBAND AND FATHER. תנצב״ה
                    """,
                tags: ["Hanner"]),
            relationships: [.init(type: .parentChild, person1Ref: "p2", person2Ref: "p1")],
            links: ["p1": people.marcus, "p2": people.isaac])
    }

    // MARK: Helpers

    func person(_ type: NameType, _ given: String, _ surname: String) throws -> Person {
        try person(names: [PersonName.deriving(type: type, given: given, surname: surname)])
    }

    func person(names: [PersonName]) throws -> Person {
        try archive.addPerson(PersonDraft(names: names))
    }

    func facts(_ person: Person, _ facts: PersonFact...) throws {
        _ = try archive.updatePerson(person.uid) { $0.facts = facts }
    }

    /// The links written for `"document/ref"` keys, in order.
    func cite(_ keys: String...) throws -> [EvidenceLinkID] {
        try keys.map { key in
            guard let link = links[key] else { throw SampleArchiveError.unknownLink(key) }
            return link
        }
    }

    func couple(_ a: Person, _ b: Person, _ facts: PersonFact...) throws {
        try archive.addRelationship(
            RelationshipDraft(
                type: .couple, person1Uid: a.uid, person2Uid: b.uid, facts: facts,
                supportedByLinks: facts.flatMap(\.supportedByLinks)))
    }

    func parent(_ parent: Person, of child: Person, citing key: String? = nil) throws {
        try archive.addRelationship(
            RelationshipDraft(
                type: .parentChild, person1Uid: parent.uid, person2Uid: child.uid,
                supportedByLinks: try key.map { try cite($0) } ?? []))
    }

    /// Adds one document with its page, its within-record relationships, and its links.
    mutating func document(
        _ key: String, page: String, _ draft: ArtifactDraft,
        relationships: [MentionRelationship] = [], links people: [String: Person]
    ) throws {
        let artifact = try archive.addArtifact(draft)
        guard
            let pageURL = Bundle.module.url(
                forResource: page, withExtension: nil, subdirectory: "pages")
        else { throw SampleArchiveError.missingPage(page) }
        try archive.attachFile(copyingFrom: pageURL, to: artifact.uid, role: .accessCopy)
        if !relationships.isEmpty {
            try archive.updateMetadata(of: artifact.uid) { $0.mentionRelationships = relationships }
        }
        for (ref, person) in people.sorted(by: { $0.key < $1.key }) {
            let decision = try archive.link(
                MentionRef(artifact: artifact.uid, localRef: ref), to: person.uid)
            links["\(key)/\(ref)"] = decision.link.uid
        }
    }

    func mention(
        _ ref: String, _ name: String, _ role: PersonRole = .subject,
        _ quality: InformationQuality = .primary, age: String? = nil,
        facts: [RecordedFact] = [], language: String? = nil, script: String? = nil
    ) -> PersonMention {
        PersonMention(
            localRef: ref, nameAsRecorded: name, role: role, informationQuality: quality,
            facts: facts, nameLanguage: language, nameScript: script,
            attributes: age.map { ["ageAsRecorded": $0] })
    }

    /// A census line: an age, the birth it implies, and where the enumerator said.
    func censusMention(
        _ ref: String, _ name: String, age: String, born: String, in birthplace: String
    ) -> PersonMention {
        mention(
            ref, name, .subject, .secondary, age: age,
            facts: [RecordedFact(type: .birth, date: born, place: birthplace)])
    }

    func householdRelationships(head: String, wife: String, children: [String])
        -> [MentionRelationship]
    {
        [MentionRelationship(type: .couple, person1Ref: head, person2Ref: wife)]
            + children.flatMap { child in
                [
                    MentionRelationship(type: .parentChild, person1Ref: head, person2Ref: child),
                    MentionRelationship(type: .parentChild, person1Ref: wife, person2Ref: child),
                ]
            }
    }
}
