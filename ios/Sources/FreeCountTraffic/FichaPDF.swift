import TrafficCore
import UIKit

/// PDF laid out like the E50 paper form "FORMATO PARA AFOROS VEHICULARES Y TIEMPOS DE RECORRIDO": A4 landscape, one
/// series of sheets per movement, six 15-minute periods per sheet, every cell with tally marks (a crossed square per
/// 5 vehicles) and its total. A last page sums each movement and warns about trucks still to classify.
enum FichaPDF {
    private static let page = CGRect(x: 0, y: 0, width: 842, height: 595)
    private static let margin: CGFloat = 22
    private static let rowsPerSheet = 6
    /// Filled-in values are written in blue, like a pen on the printed form.
    private static let pen = UIColor(red: 0.05, green: 0.20, blue: 0.55, alpha: 1)
    private static let ink = UIColor.black
    private static let subtitle = "FORMATO PARA AFOROS VEHICULARES Y TIEMPOS DE RECORRIDO"

    // column widths: PER, MOV, the 7 printed categories, OBSERVACIONES (they add up to 842 - 2 * 22)
    private static let widths: [CGFloat] = [50, 62, 132, 104, 76, 76, 76, 76, 92, 54]
    private static let headers = ["AUTOS/CAMIONETAS", "BUS - 2 ejes", "C-2G", "C-3-4", "C5", "≥C6", "Motos"]

    // MARK: data

    private static func table(_ r: SessionRecord) -> FichaTable {
        Ficha.table(r.events, zones: r.zones, durationMs: Int64(r.durationMs), dayOffsetMs: r.dayOffsetMs)
    }

    private static func hhmm(_ msOfDay: Int64) -> String {
        let m = Int((msOfDay / 60_000) % (24 * 60))
        return String(format: "%02d:%02d", m / 60, m % 60)
    }

    private static func dateText(_ r: SessionRecord) -> String {
        let f = DateFormatter()
        f.dateFormat = "dd/MM/yyyy"
        return f.string(from: r.clockStart ?? r.startedAt)
    }

    private static func hours(_ r: SessionRecord) -> (String, String) {
        let start = r.dayOffsetMs
        return (hhmm(start), hhmm(start + Int64(r.durationMs)))
    }

    private static func hhmmss(_ msOfDay: Int64) -> String {
        let s = Int((msOfDay / 1000) % (24 * 3600))
        return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }

    /// What goes in the OBSERVACIONES column of a period.
    private static func notes(_ counts: [FichaCategory: Int], _ p: FichaPeriod, first: Bool, last: Bool, _ r: SessionRecord) -> String {
        var out: [String] = []
        if p.partial && first { out.append("Inicia \(hhmmss(r.dayOffsetMs))") }
        if p.partial && last { out.append("Termina \(hhmmss(r.dayOffsetMs + Int64(r.durationMs)))") }
        if let n = counts[.sinClasificar], n > 0 { out.append("\(n) camión(es) sin clasificar") }
        if let n = counts[.bicicletas], n > 0 { out.append("\(n) bicicleta(s)") }
        return out.joined(separator: ". ")
    }

    /// The form's table as CSV: one row per period and movement, with the same categories as the Colab notebook.
    static func csv(_ r: SessionRecord) -> String {
        let t = table(r)
        let cats = FichaCategory.allCases
        var out = "periodo_inicio,periodo_fin,movimiento," + cats.map { $0.rawValue }.joined(separator: ",") + ",TOTAL,OBSERVACIONES\n"
        for (m, movement) in t.movements.enumerated() {
            for (i, p) in t.periods.enumerated() {
                let c = t.counts[m][i]
                let note = notes(c, p, first: i == 0, last: i == t.periods.count - 1, r)
                out += "\(hhmm(p.startOfDayMs)),\(hhmm(p.endOfDayMs)),\"\(movement)\","
                out += cats.map { String(c[$0] ?? 0) }.joined(separator: ",") + ",\(c.values.reduce(0, +)),\"\(note)\"\n"
            }
        }
        return out
    }

    // MARK: PDF

    static func pdf(_ r: SessionRecord, _ info: FichaInfo) throws -> URL {
        let t = table(r)
        let sheetsPerMovement = max(1, (t.periods.count + rowsPerSheet - 1) / rowsPerSheet)
        let totalSheets = sheetsPerMovement * t.movements.count
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        let data = renderer.pdfData { ctx in
            var sheet = 0
            for (m, movement) in t.movements.enumerated() {
                for s in 0..<sheetsPerMovement {
                    sheet += 1
                    ctx.beginPage()
                    drawSheet(ctx.cgContext, r, info, t, movement: m, name: movement,
                              periods: s * rowsPerSheet..<min((s + 1) * rowsPerSheet, t.periods.count), sheet: sheet, of: totalSheets)
                }
            }
            ctx.beginPage()
            drawSummary(ctx.cgContext, r, info, t)
        }
        let safe = (r.name + "_ficha_E50.pdf").replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(safe)
        try data.write(to: url)
        return url
    }

    private static func text(_ s: String, _ rect: CGRect, size: CGFloat, bold: Bool = false, color: UIColor = ink,
                             align: NSTextAlignment = .left, vCenter: Bool = true) {
        let style = NSMutableParagraphStyle()
        style.alignment = align
        style.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size),
            .foregroundColor: color, .paragraphStyle: style,
        ]
        let str = NSAttributedString(string: s, attributes: attrs)
        let h = min(rect.height, str.boundingRect(with: CGSize(width: rect.width, height: .greatestFiniteMagnitude),
                                                  options: [.usesLineFragmentOrigin], context: nil).height)
        let y = vCenter ? rect.midY - h / 2 : rect.minY
        str.draw(with: CGRect(x: rect.minX, y: y, width: rect.width, height: rect.maxY - y),
                 options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }

    private static func stroke(_ c: CGContext, _ rect: CGRect, width: CGFloat) {
        c.setStrokeColor(ink.cgColor)
        c.setLineWidth(width)
        c.stroke(rect)
    }

    /// "Label: value___" with the value on an underline, like the blanks of the printed form.
    private static func field(_ c: CGContext, _ label: String, _ value: String, x: CGFloat, y: CGFloat, width: CGFloat) {
        let font = UIFont.systemFont(ofSize: 9.5)
        let lw = (label as NSString).size(withAttributes: [.font: font]).width + 4
        text(label, CGRect(x: x, y: y, width: lw, height: 14), size: 9.5)
        c.setStrokeColor(ink.cgColor)
        c.setLineWidth(0.6)
        c.move(to: CGPoint(x: x + lw, y: y + 13))
        c.addLine(to: CGPoint(x: x + width, y: y + 13))
        c.strokePath()
        text(value, CGRect(x: x + lw + 4, y: y - 1, width: width - lw - 4, height: 14), size: 10, color: pen)
    }

    private static func header(_ c: CGContext, _ info: FichaInfo) -> CGFloat {
        let x = margin, w = page.width - 2 * margin, y: CGFloat = 18
        let logoW: CGFloat = 200
        let box = CGRect(x: x, y: y, width: w, height: 44)
        stroke(c, box, width: 1.2)
        stroke(c, CGRect(x: x, y: y, width: logoW, height: 44), width: 1.2)
        if let logo = UIImage(named: "FichaLogo") {
            let h: CGFloat = 36
            let lw = min(logoW - 10, logo.size.width / logo.size.height * h)
            logo.draw(in: CGRect(x: x + (logoW - lw) / 2, y: y + 4, width: lw, height: h))
        }
        let right = CGRect(x: x + logoW, y: y, width: w - logoW, height: 44)
        c.move(to: CGPoint(x: right.minX, y: y + 26))
        c.addLine(to: CGPoint(x: right.maxX, y: y + 26))
        c.strokePath()
        text(info.title.uppercased(), CGRect(x: right.minX + 4, y: y, width: right.width - 8, height: 26), size: 11.5, bold: true, align: .center)
        text(subtitle, CGRect(x: right.minX + 4, y: y + 26, width: right.width - 8, height: 18), size: 9.5, bold: true, align: .center)
        return y + 44
    }

    private static func drawSheet(_ c: CGContext, _ r: SessionRecord, _ info: FichaInfo, _ t: FichaTable, movement m: Int,
                                  name: String, periods: Range<Int>, sheet: Int, of total: Int) {
        var y = header(c, info) + 8
        let x = margin, w = page.width - 2 * margin
        let (start, end) = hours(r)
        field(c, "Fecha (D.M.A):", dateText(r), x: x, y: y, width: 290)
        field(c, "Estación de Aforo:", info.station, x: x + 310, y: y, width: 488)
        y += 17
        field(c, "Condición Climática:", info.weather, x: x, y: y, width: 290)
        field(c, "Movimientos Aforados:", name, x: x + 310, y: y, width: 488)
        y += 17
        field(c, "Aforador:", info.observer, x: x, y: y, width: 600)
        field(c, "Hoja", "\(sheet)", x: x + 640, y: y, width: 70)
        field(c, "de", "\(total)", x: x + 718, y: y, width: 80)
        y += 17
        field(c, "Coordinador:", info.coordinator, x: x, y: y, width: 420)
        field(c, "Hora de Inicio:", start, x: x + 440, y: y, width: 175)
        field(c, "Hora Final:", end, x: x + 628, y: y, width: 170)
        y += 22

        // column header
        let headerH: CGFloat = 56
        var cx = x
        let cols = widths.map { wd -> CGRect in defer { cx += wd }; return CGRect(x: cx, y: y, width: wd, height: headerH) }
        text("PER", cols[0], size: 10, bold: true, align: .center)
        text("MOV", cols[1], size: 10, bold: true, align: .center)
        for (i, title) in headers.enumerated() {
            let col = cols[i + 2]
            text(title, CGRect(x: col.minX + 3, y: col.minY + 2, width: col.width - 6, height: 12), size: 7.5, bold: true,
                 align: .left)
            VehicleIcons.draw(FichaCategory.printed[i], in: CGRect(x: col.minX + 6, y: col.minY + 16, width: col.width - 12, height: 36), c)
        }
        let obs = cols[9]
        c.saveGState()
        c.translateBy(x: obs.midX, y: obs.midY)
        c.rotate(by: -.pi / 2)
        text("OBSERVACIONES", CGRect(x: -obs.height / 2, y: -obs.width / 2, width: obs.height, height: obs.width), size: 6, bold: true, align: .center)
        c.restoreGState()
        for col in cols { stroke(c, col, width: 1) }
        y += headerH

        // rows (the last sheet is completed with empty rows, like the printed form)
        let rowH = (page.height - margin - y) / CGFloat(rowsPerSheet)
        for k in 0..<rowsPerSheet {
            let i = periods.lowerBound + k
            let row = CGRect(x: x, y: y + CGFloat(k) * rowH, width: w, height: rowH)
            var cx = x
            let cells = widths.map { wd -> CGRect in defer { cx += wd }; return CGRect(x: cx, y: row.minY, width: wd, height: rowH) }
            if periods.contains(i) {
                let p = t.periods[i]
                let counts = t.counts[m][i]
                text("\(hhmm(p.startOfDayMs))\n–\n\(hhmm(p.endOfDayMs))", cells[0], size: 9.5, color: pen, align: .center)
                text(name, cells[1].insetBy(dx: 3, dy: 3), size: 8, color: pen, align: .center)
                for (j, cat) in FichaCategory.printed.enumerated() { tallyCell(c, cells[j + 2], counts[cat] ?? 0) }
                text(notes(counts, p, first: i == 0, last: i == t.periods.count - 1, r), cells[9].insetBy(dx: 2, dy: 3),
                     size: 6, color: pen, align: .left, vCenter: false)
            } else {
                for j in 2..<9 { tallyCell(c, cells[j], nil) }
            }
            for (j, cell) in cells.enumerated() { stroke(c, cell, width: j >= 2 && j <= 8 ? 1 : 0.8) }
        }
        stroke(c, CGRect(x: x, y: y, width: w, height: rowH * CGFloat(rowsPerSheet)), width: 1.4)
    }

    /// Grid of dashed squares with the tally (a square with its diagonal per 5 vehicles, then 1-4 sides) and the
    /// total in the box at the bottom right. `count` nil = blank cell.
    private static func tallyCell(_ c: CGContext, _ cell: CGRect, _ count: Int?) {
        let s: CGFloat = 8, gap: CGFloat = 2.6, pad: CGFloat = 4
        let totalBox = CGRect(x: cell.maxX - 32, y: cell.maxY - 19, width: 29, height: 16)
        var slots: [CGRect] = []
        var yy = cell.minY + pad
        while yy + s <= cell.maxY - pad {
            var xx = cell.minX + pad
            while xx + s <= cell.maxX - pad {
                let sq = CGRect(x: xx, y: yy, width: s, height: s)
                if !sq.insetBy(dx: -1, dy: -1).intersects(totalBox) { slots.append(sq) }
                xx += s + gap
            }
            yy += s + gap
        }
        c.saveGState()
        c.setStrokeColor(UIColor(white: 0.6, alpha: 1).cgColor)
        c.setLineWidth(0.4)
        c.setLineDash(phase: 0, lengths: [1.2, 1.2])
        for sq in slots { c.stroke(sq) }
        c.restoreGState()
        stroke(c, totalBox, width: 0.9)
        guard let count else { return }

        c.saveGState()
        c.setStrokeColor(pen.cgColor)
        c.setLineWidth(0.9)
        c.setLineCap(.round)
        var left = count
        for sq in slots where left > 0 {
            let n = min(left, 5)
            let a = CGPoint(x: sq.minX, y: sq.maxY), b = CGPoint(x: sq.minX, y: sq.minY)
            let d = CGPoint(x: sq.maxX, y: sq.minY), e = CGPoint(x: sq.maxX, y: sq.maxY)
            let sides = [(a, b), (b, d), (d, e), (e, a), (a, d)]   // left, top, right, bottom, diagonal
            for (p, q) in sides.prefix(n) {
                c.move(to: p)
                c.addLine(to: q)
            }
            c.strokePath()
            left -= n
        }
        c.restoreGState()
        text("\(count)", totalBox, size: 9.5, bold: true, color: pen, align: .center)
    }

    private static func drawSummary(_ c: CGContext, _ r: SessionRecord, _ info: FichaInfo, _ t: FichaTable) {
        var y = header(c, info) + 14
        let x = margin, w = page.width - 2 * margin
        let (start, end) = hours(r)
        text("RESUMEN DEL AFORO · \(dateText(r)) · \(start)–\(end)" + (info.station.isEmpty ? "" : " · \(info.station)"),
             CGRect(x: x, y: y, width: w, height: 16), size: 11, bold: true)
        y += 24
        let cats = FichaCategory.allCases
        let nameW: CGFloat = 170
        let cw = (w - nameW) / CGFloat(cats.count + 1)
        func row(_ cells: [String], bold: Bool, fill: UIColor? = nil) {
            let h: CGFloat = 22
            if let fill {
                c.setFillColor(fill.cgColor)
                c.fill(CGRect(x: x, y: y, width: w, height: h))
            }
            for (i, v) in cells.enumerated() {
                let rect = i == 0 ? CGRect(x: x, y: y, width: nameW, height: h)
                    : CGRect(x: x + nameW + CGFloat(i - 1) * cw, y: y, width: cw, height: h)
                text(v, rect.insetBy(dx: 3, dy: 1), size: bold ? 7.5 : 9, bold: bold, color: bold ? ink : pen, align: i == 0 ? .left : .center)
                stroke(c, rect, width: 0.7)
            }
            y += h
        }
        row(["MOVIMIENTO"] + cats.map { $0.rawValue } + ["TOTAL"], bold: true, fill: UIColor(white: 0.9, alpha: 1))
        var sums = [FichaCategory: Int]()
        for (m, name) in t.movements.enumerated() {
            let vals = cats.map { t.total(movement: m, $0) }
            for (cat, v) in zip(cats, vals) { sums[cat, default: 0] += v }
            row([name] + vals.map(String.init) + [String(vals.reduce(0, +))], bold: false)
        }
        row(["TOTAL"] + cats.map { String(sums[$0] ?? 0) } + [String(sums.values.reduce(0, +))], bold: true, fill: UIColor(white: 0.9, alpha: 1))

        y += 14
        let pending = sums[.sinClasificar] ?? 0
        if pending > 0 {
            text("⚠ Hay \(pending) camión(es) SIN CLASIFICAR: el aforo no está completo. Clasifícalos por ejes en la app "
                 + "(Results → Classify trucks) y vuelve a generar la ficha.",
                 CGRect(x: x, y: y, width: w, height: 30), size: 10, bold: true, color: UIColor(red: 0.7, green: 0.3, blue: 0, alpha: 1),
                 vCenter: false)
            y += 34
        }
        text("Conteo automático en el teléfono (YOLO); camiones clasificados por ejes por el aforador a partir de su foto. "
             + "Las furgonetas se cuentan en AUTOS/CAMIONETAS. Las bicicletas y los camiones sin clasificar no tienen columna "
             + "en la ficha: aparecen en OBSERVACIONES. Sesión: \(r.name).",
             CGRect(x: x, y: y, width: w, height: 40), size: 8, color: UIColor.darkGray, vCenter: false)
    }
}

/// Line drawings of the form's vehicle columns, side view facing left.
enum VehicleIcons {
    static func draw(_ cat: FichaCategory, in rect: CGRect, _ c: CGContext) {
        c.saveGState()
        c.setStrokeColor(UIColor.black.cgColor)
        c.setLineWidth(0.9)
        c.setLineJoin(.round)
        // drawing space 100 x 40 scaled into rect, keeping the aspect
        let s = min(rect.width / 100, rect.height / 40)
        c.translateBy(x: rect.midX - 50 * s, y: rect.midY - 20 * s)
        c.scaleBy(x: s, y: s)
        c.setLineWidth(0.9 / s)
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, r: CGFloat = 1.5) {
            c.addPath(UIBezierPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r).cgPath)
        }
        func wheels(_ xs: [CGFloat], r: CGFloat = 4.2) {
            for x in xs {
                c.addEllipse(in: CGRect(x: x - r, y: 34 - r, width: 2 * r, height: 2 * r))
                c.addEllipse(in: CGRect(x: x - r / 2.5, y: 34 - r / 2.5, width: 2 * r / 2.5, height: 2 * r / 2.5))
            }
        }
        /// Cab facing left, starting at x: windscreen, door and window.
        func cab(_ x: CGFloat, w: CGFloat = 16) {
            c.move(to: CGPoint(x: x, y: 32))
            c.addLine(to: CGPoint(x: x, y: 16))
            c.addLine(to: CGPoint(x: x + 4, y: 9))
            c.addLine(to: CGPoint(x: x + w, y: 9))
            c.addLine(to: CGPoint(x: x + w, y: 32))
            c.closePath()
            box(x + 2.5, 11.5, w - 6, 6, r: 0.8)
        }
        switch cat {
        case .autos:
            c.move(to: CGPoint(x: 8, y: 32))
            c.addLine(to: CGPoint(x: 6, y: 24))
            c.addLine(to: CGPoint(x: 24, y: 20))
            c.addLine(to: CGPoint(x: 36, y: 11))
            c.addLine(to: CGPoint(x: 64, y: 11))
            c.addLine(to: CGPoint(x: 78, y: 20))
            c.addLine(to: CGPoint(x: 94, y: 22))
            c.addLine(to: CGPoint(x: 94, y: 32))
            c.closePath()
            c.move(to: CGPoint(x: 30, y: 20)); c.addLine(to: CGPoint(x: 39, y: 14)); c.addLine(to: CGPoint(x: 49, y: 14)); c.addLine(to: CGPoint(x: 49, y: 20)); c.closePath()
            c.move(to: CGPoint(x: 53, y: 20)); c.addLine(to: CGPoint(x: 53, y: 14)); c.addLine(to: CGPoint(x: 62, y: 14)); c.addLine(to: CGPoint(x: 71, y: 20)); c.closePath()
            wheels([24, 76], r: 5)
        case .bus:
            box(4, 6, 92, 26, r: 3)
            for i in 0..<8 { box(9 + CGFloat(i) * 10.5, 10, 8, 8, r: 0.8) }
            c.move(to: CGPoint(x: 4, y: 22)); c.addLine(to: CGPoint(x: 96, y: 22))
            wheels([20, 80])
        case .c2g:
            cab(6); box(24, 4, 70, 28)
            wheels([14, 78])
        case .c34:
            cab(6); box(24, 4, 70, 28)
            wheels([14, 70, 82])
        case .c5:
            cab(4, w: 15); box(21, 6, 77, 22)
            c.move(to: CGPoint(x: 19, y: 30)); c.addLine(to: CGPoint(x: 98, y: 30))
            wheels([11, 25, 34, 80, 90], r: 3.8)
        case .c6:
            cab(3, w: 14); box(19, 6, 79, 22)
            c.move(to: CGPoint(x: 17, y: 30)); c.addLine(to: CGPoint(x: 98, y: 30))
            wheels([9, 22, 30, 73, 81, 89], r: 3.5)
        case .motos, .bicicletas:
            wheels([22, 78], r: 9)
            c.move(to: CGPoint(x: 22, y: 34)); c.addLine(to: CGPoint(x: 34, y: 16)); c.addLine(to: CGPoint(x: 30, y: 10))
            c.move(to: CGPoint(x: 34, y: 20)); c.addLine(to: CGPoint(x: 66, y: 20)); c.addLine(to: CGPoint(x: 78, y: 34))
            box(44, 14, 18, 6, r: 2)
        case .sinClasificar:
            break
        }
        c.strokePath()
        c.restoreGState()
    }
}
