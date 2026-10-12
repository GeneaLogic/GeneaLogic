// Renders the sample archive's page images (slice 74b).
//
// Usage: swift scripts/render-sample-pages.swift [output-dir]
//   default output: GeneaLogicKit/Sources/GeneaLogicSample/Resources/pages
//
// macOS only (AppKit and ImageIO). The output is committed, so this runs only when a
// page changes; the engine copies the bytes and never renders anything. Every person,
// place detail and record number here is invented, and each page says so in its footer.
// The text must agree with the records `SampleArchive` writes for the same document.

import AppKit
import ImageIO
import UniformTypeIdentifiers

let outputDir = URL(
    fileURLWithPath: CommandLine.arguments.count > 1
        ? CommandLine.arguments[1]
        : "GeneaLogicKit/Sources/GeneaLogicSample/Resources/pages",
    isDirectory: true)
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

// MARK: - Style

func font(_ name: String, _ size: CGFloat) -> NSFont { NSFont(name: name, size: size)! }

let ink = NSColor(srgbRed: 0.14, green: 0.13, blue: 0.12, alpha: 1)
let pen = NSColor(srgbRed: 0.12, green: 0.16, blue: 0.32, alpha: 1)
let faded = NSColor(srgbRed: 0.40, green: 0.37, blue: 0.33, alpha: 1)
let paper = NSColor(srgbRed: 0.95, green: 0.92, blue: 0.85, alpha: 1)

let printed = { (size: CGFloat) in font("Baskerville", size) }
let printedBold = { (size: CGFloat) in font("Baskerville-SemiBold", size) }
let typed = { (size: CGFloat) in font("AmericanTypewriter", size) }
let hand = { (size: CGFloat) in font("BradleyHandITCTT-Bold", size) }

let footerText = "GeneaLogic sample archive · an invented record about invented people"

// MARK: - Drawing

/// Lays items down a page from the top, in a flipped (top-left origin) context.
final class Page {
    let size: CGSize
    let margin: CGFloat
    var y: CGFloat

    init(size: CGSize, margin: CGFloat = 70) {
        self.size = size
        self.margin = margin
        self.y = margin
    }

    var width: CGFloat { size.width - 2 * margin }

    func text(
        _ string: String, _ font: NSFont, color: NSColor = ink,
        align: NSTextAlignment = .left, after: CGFloat = 8, x: CGFloat? = nil,
        width: CGFloat? = nil
    ) {
        let style = NSMutableParagraphStyle()
        style.alignment = align
        style.lineSpacing = 4
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: style,
        ]
        let w = width ?? self.width
        let bounds = (string as NSString).boundingRect(
            with: CGSize(width: w, height: 10_000), options: [.usesLineFragmentOrigin],
            attributes: attributes)
        (string as NSString).draw(
            with: CGRect(x: x ?? margin, y: y, width: w, height: ceil(bounds.height)),
            options: [.usesLineFragmentOrigin], attributes: attributes)
        y += ceil(bounds.height) + after
    }

    func rule(weight: CGFloat = 1, after: CGFloat = 12) {
        ink.withAlphaComponent(0.7).setStroke()
        let path = NSBezierPath()
        path.lineWidth = weight
        path.move(to: CGPoint(x: margin, y: y))
        path.line(to: CGPoint(x: size.width - margin, y: y))
        path.stroke()
        y += after
    }

    /// A printed label with a handwritten value on a ruled line.
    func field(_ label: String, _ value: String, labelWidth: CGFloat = 230) {
        let top = y
        text(label, printed(19), color: faded, after: 0, width: labelWidth)
        let labelBottom = y
        y = top - 6
        text(
            value, hand(25), color: pen, after: 0, x: margin + labelWidth,
            width: width - labelWidth)
        y = max(y, labelBottom) + 2
        faded.withAlphaComponent(0.5).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 0.8
        path.move(to: CGPoint(x: margin + labelWidth, y: y))
        path.line(to: CGPoint(x: size.width - margin, y: y))
        path.stroke()
        y += 14
    }

    /// A ruled register: printed headers, handwritten rows.
    func table(
        headers: [String], widths: [CGFloat], rows: [[String]], rowHeight: CGFloat = 44,
        headerFont: NSFont = printed(15), cellFont: NSFont = hand(22),
        blankRows: Int = 0
    ) {
        let total = widths.reduce(0, +)
        let scale = width / total
        let columns = widths.map { $0 * scale }
        let top = y
        var x = margin
        var headerHeight: CGFloat = 0
        for (header, w) in zip(headers, columns) {
            y = top + 6
            text(
                header, headerFont, color: faded, align: .center, after: 0, x: x + 4,
                width: w - 8)
            headerHeight = max(headerHeight, y - top + 6)
            x += w
        }
        y = top + headerHeight
        rule(weight: 1.5, after: 0)
        let tableTop = top
        for row in rows + Array(repeating: [], count: blankRows) {
            let rowTop = y
            x = margin
            for (i, w) in columns.enumerated() where i < row.count {
                y = rowTop + 6
                text(row[i], cellFont, color: pen, after: 0, x: x + 6, width: w - 12)
                x += w
            }
            y = rowTop + rowHeight
            rule(weight: 0.6, after: 0)
        }
        // Column dividers.
        ink.withAlphaComponent(0.5).setStroke()
        x = margin
        for w in columns.dropLast() {
            x += w
            let path = NSBezierPath()
            path.lineWidth = 0.6
            path.move(to: CGPoint(x: x, y: tableTop))
            path.line(to: CGPoint(x: x, y: y))
            path.stroke()
        }
        y += 16
    }

    func footer(color: NSColor = faded) {
        y = size.height - margin * 0.6 - 16
        text(
            footerText, font("Optima-Regular", 13), color: color.withAlphaComponent(0.8),
            align: .center, after: 0)
    }
}

/// Paper: a flat ground darkening slightly toward the edges (cheap for JPEG).
func drawPaper(_ size: CGSize, ground: NSColor = paper) {
    ground.setFill()
    CGRect(origin: .zero, size: size).fill()
    let edge = NSGradient(colors: [
        NSColor.clear, NSColor(srgbRed: 0.55, green: 0.45, blue: 0.30, alpha: 0.18),
    ])!
    edge.draw(
        in: NSBezierPath(rect: CGRect(origin: .zero, size: size)),
        relativeCenterPosition: .zero)
}

func render(
    _ name: String, size: CGSize, exif: [CFString: Any]? = nil, _ draw: (Page) -> Void
) throws {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    // Flip to a top-left origin so pages read top-down.
    context.cgContext.translateBy(x: 0, y: size.height)
    context.cgContext.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
    draw(Page(size: size))
    NSGraphicsContext.current = nil

    let url = outputDir.appendingPathComponent(name)
    let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.62]
    if let exif { properties[kCGImagePropertyExifDictionary] = exif }
    CGImageDestinationAddImage(destination, rep.cgImage!, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { fatalError("could not write \(name)") }
    let bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    print("\(name)  \(bytes / 1024) KB")
}

let letter = CGSize(width: 1000, height: 1294)

// MARK: - 1862: a birth in a Russian metrical book

try render("1862-sternfeld-birth.jpg", size: CGSize(width: 1300, height: 760)) { page in
    drawPaper(page.size)
    page.text(
        "Метрическая книга о родившихся евреях", printedBold(30), align: .center, after: 4)
    page.text(
        "Коростышевский казённый раввин · 1862 год · Часть первая", printed(21),
        color: faded, align: .center, after: 26)
    page.table(
        headers: [
            "№", "Число и месяц рождения", "Состояние отца, имена отца и матери",
            "Где родился", "Имя родившегося",
        ],
        widths: [50, 170, 330, 170, 160],
        rows: [
            [
                "45", "28 февраля", "мещанин Мордух Лейбов Гринберг и жена его Хая", "Коростышев",
                "Хана",
            ],
            [
                "46", "1 марта", "мещанин Шлема Абрамов Цукерман и жена его Рейзя", "Коростышев",
                "Мошко",
            ],
            [
                "47", "3 марта", "мещанин Берек Иосифов Штернфельд и жена его Сура",
                "Коростышев", "Гитля",
            ],
        ], rowHeight: 92, headerFont: printed(17), cellFont: hand(23), blankRows: 2)
    page.footer()
}

// MARK: - 1906: a passenger manifest

try render("1906-ship-manifest.jpg", size: CGSize(width: 1500, height: 860)) { page in
    drawPaper(page.size)
    page.text(
        "LIST OR MANIFEST OF ALIEN PASSENGERS FOR THE UNITED STATES IMMIGRATION OFFICER AT PORT OF ARRIVAL",
        printedBold(21), align: .center, after: 6)
    page.text(
        "S.S. Weichsel   sailing from Hamburg, April 28th, 1906   Arriving at Port of New York, May 14th, 1906",
        printed(19), color: faded, align: .center, after: 22)
    page.table(
        headers: [
            "No.", "Name in full", "Age", "Sex", "Calling or occupation", "Nationality",
            "Last residence", "Final destination",
        ],
        widths: [40, 220, 50, 45, 150, 110, 140, 140],
        rows: [
            ["12", "Rosen, Dwora", "34", "F", "wife", "Russia", "Plock", "New York"],
            ["13", "Rosen, Chaim", "9", "M", "child", "Russia", "Plock", "New York"],
            ["14", "Hanaur, Markus", "22", "M", "tailor", "Russia", "Rypin", "New York"],
            ["15", "Kaplan, Herszel", "19", "M", "joiner", "Russia", "Wloclawek", "Chicago"],
        ], rowHeight: 56, cellFont: hand(25), blankRows: 4)
    page.footer()
}

// MARK: - 1910: a marriage certificate

try render("1910-marriage-certificate.jpg", size: letter) { page in
    drawPaper(page.size)
    page.text("CITY OF NEW YORK", printed(20), color: faded, align: .center, after: 2)
    page.text("BOROUGH OF BROOKLYN", printed(20), color: faded, align: .center, after: 14)
    page.text("Certificate and Record of Marriage", font("Didot", 40), align: .center, after: 6)
    page.text("No. 11482", printed(18), color: faded, align: .center, after: 22)
    page.rule(weight: 1.5, after: 20)
    page.field("Groom's name", "Marcus Hanner")
    page.field("Age", "26")
    page.field("Birthplace", "Rypin, Russia")
    page.field("Father's name", "Isaac Hanner")
    page.field("Mother's maiden name", "Esther Kahn")
    page.y += 10
    page.field("Bride's name", "Fay Feldberg")
    page.field("Age", "21")
    page.field("Birthplace", "Kutno, Russia")
    page.field("Father's name", "Solomon Feldberg")
    page.field("Mother's maiden name", "Gussie Sternfeld")
    page.y += 10
    page.field("Date of marriage", "June 12th, 1910")
    page.field("Place of marriage", "Brooklyn, N.Y.")
    page.y += 30
    page.text(
        "I hereby certify that the above-named groom and bride were joined in marriage by me, in accordance with the laws of the State of New York.",
        printed(18), color: faded, after: 30)
    page.field("Officiating", "Rabbi A. Levy", labelWidth: 160)
    page.footer()
}

// MARK: - 1915: a state census household

try render("1915-state-census.jpg", size: CGSize(width: 1400, height: 820)) { page in
    drawPaper(page.size)
    page.text("STATE OF NEW YORK — CENSUS OF 1915", printedBold(26), align: .center, after: 4)
    page.text(
        "County of Kings · Borough of Brooklyn · Assembly District 6 · Election District 21 · Block 12",
        printed(18), color: faded, align: .center, after: 22)
    page.table(
        headers: [
            "Street", "Name of each person whose usual place of abode was in this family",
            "Relation to head", "Sex", "Age", "Nativity", "Years in U.S.", "Occupation",
        ],
        widths: [110, 280, 110, 50, 50, 110, 80, 130],
        rows: [
            ["Siegel St.", "Hanner, Marcus", "Head", "M", "31", "Russia", "9", "tailor"],
            ["", "Hanner, Fay", "Wife", "F", "26", "Russia", "8", "housework"],
            ["", "Hanner, Irving", "Son", "M", "3", "U.S.", "", ""],
            ["", "Hanner, Rose", "Daughter", "F", "0", "U.S.", "", ""],
        ], rowHeight: 56, cellFont: hand(25), blankRows: 4)
    page.footer()
}

// MARK: - 1920: a federal census household

try render("1920-federal-census.jpg", size: CGSize(width: 1500, height: 860)) { page in
    drawPaper(page.size)
    page.text(
        "DEPARTMENT OF COMMERCE — BUREAU OF THE CENSUS", printed(18), color: faded,
        align: .center, after: 2)
    page.text(
        "FOURTEENTH CENSUS OF THE UNITED STATES: 1920 — POPULATION", printedBold(26),
        align: .center, after: 4)
    page.text(
        "State New York · County Kings · Borough of Brooklyn · Ward 3 · Enumeration District 412 · Enumerated January 5, 1920",
        printed(18), color: faded, align: .center, after: 22)
    page.table(
        headers: [
            "Name", "Relation", "Sex", "Age", "Place of birth", "Year of immigration",
            "Trade or profession",
        ],
        widths: [260, 150, 50, 50, 150, 110, 150],
        rows: [
            ["Honner, Marcus", "Head", "M", "35", "Poland", "1906", "tailor"],
            ["— Faye", "Wife", "F", "30", "Poland", "1907", "none"],
            ["— Irving", "Son", "M", "7", "New York", "", ""],
            ["— Rose", "Daughter", "F", "4", "New York", "", ""],
            ["Feldberg, Solomon", "Father-in-law", "M", "61", "Poland", "1907", "presser"],
            ["— Gussie", "Mother-in-law", "F", "57", "Russia", "1907", "none"],
        ], rowHeight: 56, cellFont: hand(25), blankRows: 2)
    page.footer()
}

// MARK: - 1925: the back of a family photograph

try render(
    "1925-portrait-reverse.jpg", size: CGSize(width: 1000, height: 660),
    exif: [
        kCGImagePropertyExifDateTimeOriginal: "1925:06:14 11:30:00",
        kCGImagePropertyExifUserComment: "Reverse of a cabinet photograph, scanned 2026",
    ]
) { page in
    drawPaper(page.size, ground: NSColor(srgbRed: 0.93, green: 0.90, blue: 0.82, alpha: 1))
    // The studio's stamp.
    NSColor(srgbRed: 0.45, green: 0.22, blue: 0.20, alpha: 0.55).setStroke()
    let stamp = NSBezierPath(
        roundedRect: CGRect(x: 610, y: 60, width: 320, height: 120), xRadius: 10, yRadius: 10)
    stamp.lineWidth = 3
    stamp.stroke()
    page.y = 78
    page.text(
        "KESSLER STUDIO\nFine Portraits\nPitkin Avenue · Brooklyn", font("Copperplate", 22),
        color: NSColor(srgbRed: 0.45, green: 0.22, blue: 0.20, alpha: 0.7), align: .center,
        after: 0, x: 610, width: 320)
    page.y = 260
    page.text("Marcus, Fay, Irving & Rose", font("SnellRoundhand", 54), color: pen, after: 10)
    page.text("Brooklyn — June 1925", font("SnellRoundhand", 44), color: pen, after: 0)
    page.footer()
}

// MARK: - 1927: a certificate of naturalization

try render("1927-naturalization.jpg", size: letter) { page in
    drawPaper(page.size)
    page.text("No. 2384117", printed(20), color: faded, align: .right, after: 10)
    page.text("THE UNITED STATES OF AMERICA", printed(24), color: faded, align: .center, after: 6)
    page.text("Certificate of Naturalization", font("Didot", 44), align: .center, after: 24)
    page.rule(weight: 1.5, after: 20)
    page.field("Petition volume", "212, page 77", labelWidth: 260)
    page.field("Name", "Marcus Hanner", labelWidth: 260)
    page.field("Age", "43 years", labelWidth: 260)
    page.field("Born", "Rypin, Poland, March 2nd, 1884", labelWidth: 260)
    page.field("Arrived", "New York, May 14th, 1906", labelWidth: 260)
    page.field("Residence", "Brooklyn, N.Y.", labelWidth: 260)
    page.field("Wife", "Fay, 38, Brooklyn, N.Y.", labelWidth: 260)
    page.field("Minor children", "Irving 15 · Rose 12", labelWidth: 260)
    page.y += 26
    page.text(
        "Be it remembered that the above-named, then residing in Brooklyn, New York, who previous to his naturalization was a subject of Poland, having applied to be admitted a citizen of the United States of America, and the court having found that he intends to reside permanently in the United States, it was ordered that he be admitted as a citizen of the United States of America.",
        printed(19), color: faded, after: 24)
    page.text(
        "In testimony whereof the seal of said court is hereunto affixed on the 14th day of October in the year of our Lord nineteen hundred and twenty-seven.",
        printed(19), color: faded, after: 0)
    page.footer()
}

// MARK: - 1938: a death certificate

try render("1938-death-certificate.jpg", size: letter) { page in
    drawPaper(page.size)
    page.text(
        "DEPARTMENT OF HEALTH OF THE CITY OF NEW YORK", printed(20), color: faded,
        align: .center, after: 4)
    page.text("Certificate of Death", font("Didot", 42), align: .center, after: 4)
    page.text(
        "Borough of Brooklyn · No. 4102", printed(18), color: faded, align: .center, after: 20)
    page.rule(weight: 1.5, after: 20)
    page.field("Full name", "Sidney Feldberg")
    page.field("Date of death", "February 9th, 1938")
    page.field("Place of death", "Brooklyn, N.Y.")
    page.field("Age", "45 years")
    page.field("Birthplace", "Kutno, Poland")
    page.field("Occupation", "furrier")
    page.field("Father's name", "Solomon Feldberg")
    page.field("Mother's maiden name", "Gussie Sternfeld")
    page.y += 10
    page.field("Informant", "Mrs. Fay Hanner, sister")
    page.field("Burial", "February 10th, 1938")
    page.footer()
}

// MARK: - 1951: a gravestone

try render("1951-gravestone.jpg", size: CGSize(width: 900, height: 1100)) { page in
    NSColor(srgbRed: 0.34, green: 0.38, blue: 0.30, alpha: 1).setFill()
    CGRect(origin: .zero, size: page.size).fill()
    // The stone: a rounded-top tablet.
    let stone = NSBezierPath()
    let left: CGFloat = 130
    let right: CGFloat = 770
    let top: CGFloat = 120
    let bottom: CGFloat = 1000
    stone.move(to: CGPoint(x: left, y: bottom))
    stone.line(to: CGPoint(x: left, y: top + 140))
    stone.curve(
        to: CGPoint(x: right, y: top + 140), controlPoint1: CGPoint(x: left, y: top - 40),
        controlPoint2: CGPoint(x: right, y: top - 40))
    stone.line(to: CGPoint(x: right, y: bottom))
    stone.close()
    NSColor(srgbRed: 0.70, green: 0.69, blue: 0.66, alpha: 1).setFill()
    stone.fill()
    let carved = NSColor(srgbRed: 0.25, green: 0.24, blue: 0.23, alpha: 1)
    let inner = page.size.width - 2 * 170
    page.y = 250
    page.text(
        "פ״נ", font("Times-Roman", 44), color: carved, align: .center, after: 10, x: 170,
        width: inner)
    page.text(
        "מאיר בן יצחק", font("Times-Roman", 52), color: carved, align: .center,
        after: 36, x: 170, width: inner)
    page.text(
        "MARCUS HANNER", font("Optima-Regular", 46), color: carved, align: .center,
        after: 14, x: 170, width: inner)
    page.text(
        "MARCH 2, 1884", font("Optima-Regular", 30), color: carved, align: .center,
        after: 4, x: 170, width: inner)
    page.text(
        "JANUARY 17, 1951", font("Optima-Regular", 30), color: carved, align: .center,
        after: 30, x: 170, width: inner)
    page.text(
        "BELOVED HUSBAND AND FATHER", font("Optima-Regular", 26), color: carved,
        align: .center, after: 40, x: 170, width: inner)
    page.text(
        "תנצב״ה", font("Times-Roman", 44), color: carved, align: .center, after: 0,
        x: 170, width: inner)
    page.footer(color: NSColor(white: 0.9, alpha: 1))
}
