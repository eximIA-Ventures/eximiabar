import Foundation

/// Emits the three parts a native Excel chart needs: the chart itself, the drawing that anchors it to
/// a sheet, and the relationship between them.
///
/// **The shape of the problem.** A worksheet never points at a chart directly. `sheetN.xml` points at
/// a *drawing*, the drawing's rels point at the *charts*, and `[Content_Types].xml` declares both.
/// One chart more is one file more with the same skeleton and different series references — repetition,
/// not growing complexity.
///
/// **The failure mode that no automated check here catches.** A chart with a wrong series reference
/// opens **empty, with no error**: the package is valid, the schema is satisfied, every parser is
/// happy, and the plot area is blank. That is why every series also carries a value cache read from the
/// real cells (see ``XLSXRangeResolver``) — it turns an invisible failure into a comparable value — and
/// why the story still requires a human to open the file in Excel before it closes.
enum XLSXChartXML {
    /// The two axis ids, shared by every chart part.
    ///
    /// They must be the **same pair** inside the plot element, `<c:catAx>` and `<c:valAx>`, with
    /// `crossAx` pointing the other way in each. Mismatched, the chart does not render at all — and
    /// nothing reports an error. Reusing the same numbers across parts is safe: ids are scoped to
    /// their own chart part.
    private static let categoryAxisID = 111_111_111
    private static let valueAxisID = 222_222_222

    // MARK: - chartN.xml

    static func chartSpace(_ plan: XLSXWriter.ChartPlan, resolver: some XLSXRangeResolver) -> String {
        let chart = plan.chart
        var xml = XLSXWriter.xmlHeader
        xml += #"<c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">"#
        xml += "<c:chart>"
        xml += "<c:title><c:tx><c:rich><a:bodyPr/><a:p><a:r><a:t>"
        xml += XLSXWriter.escape(chart.title)
        xml += #"</a:t></a:r></a:p></c:rich></c:tx><c:overlay val="0"/></c:title>"#
        xml += #"<c:autoTitleDeleted val="0"/>"#
        xml += "<c:plotArea><c:layout/>"
        xml += plotElement(chart, resolver: resolver)
        if chart.kind != .pie {
            xml += axes(chart)
        }
        xml += "</c:plotArea>"
        xml += #"<c:legend><c:legendPos val="r"/><c:overlay val="0"/></c:legend>"#
        xml += #"<c:plotVisOnly val="1"/>"#
        // `gap` is what turns a day with no data into a break in the line instead of a drop to zero —
        // the whole point of writing blanks rather than zeros on the sheet.
        xml += #"<c:dispBlanksAs val="gap"/>"#
        xml += "</c:chart></c:chartSpace>"
        return xml
    }

    /// The type-specific plot element. Child order inside each is fixed by the schema.
    private static func plotElement(_ chart: XLSXChart, resolver: some XLSXRangeResolver) -> String {
        let sers = chart.series.enumerated()
            .map { series(index: $0.offset, series: $0.element, chart: chart, resolver: resolver) }
            .joined()

        switch chart.kind {
        case .line:
            // CT_LineChart: grouping, varyColors, ser*, marker, axId, axId.
            return #"<c:lineChart><c:grouping val="standard"/><c:varyColors val="0"/>"#
                + sers
                + #"<c:marker val="1"/>"#
                + axisIDs()
                + "</c:lineChart>"
        case .columnStacked:
            // CT_BarChart: barDir, grouping, varyColors, ser*, gapWidth, overlap, axId, axId.
            // `overlap=100` is not cosmetic — without it a "stacked" chart draws the series side by side.
            return #"<c:barChart><c:barDir val="col"/><c:grouping val="stacked"/><c:varyColors val="0"/>"#
                + sers
                + #"<c:gapWidth val="80"/><c:overlap val="100"/>"#
                + axisIDs()
                + "</c:barChart>"
        case .barHorizontal:
            return #"<c:barChart><c:barDir val="bar"/><c:grouping val="clustered"/><c:varyColors val="0"/>"#
                + sers
                + #"<c:gapWidth val="60"/><c:overlap val="-27"/>"#
                + axisIDs()
                + "</c:barChart>"
        case .pie:
            // CT_PieChart: varyColors, ser*, firstSliceAng. No axes at all.
            return #"<c:pieChart><c:varyColors val="1"/>"#
                + sers
                + #"<c:firstSliceAng val="0"/>"#
                + "</c:pieChart>"
        }
    }

    private static func axisIDs() -> String {
        #"<c:axId val="\#(categoryAxisID)"/><c:axId val="\#(valueAxisID)"/>"#
    }

    /// The category and value axes.
    ///
    /// `<c:delete val="0"/>` is required on each: omit it and Excel hides the axis, which reads as a
    /// broken chart rather than a missing attribute.
    private static func axes(_ chart: XLSXChart) -> String {
        let numberFormat = chart.valueNumberFormat.map {
            #"<c:numFmt formatCode="\#(XLSXWriter.escape($0))" sourceLinked="0"/>"#
        } ?? ""
        // A horizontal bar chart puts categories on the left and values along the bottom.
        let categoryPosition = chart.kind == .barHorizontal ? "l" : "b"
        let valuePosition = chart.kind == .barHorizontal ? "b" : "l"
        var xml = ""
        xml += #"<c:catAx><c:axId val="\#(categoryAxisID)"/>"#
        xml += #"<c:scaling><c:orientation val="minMax"/></c:scaling><c:delete val="0"/>"#
        xml += #"<c:axPos val="\#(categoryPosition)"/><c:crossAx val="\#(valueAxisID)"/></c:catAx>"#
        xml += #"<c:valAx><c:axId val="\#(valueAxisID)"/>"#
        xml += #"<c:scaling><c:orientation val="minMax"/></c:scaling><c:delete val="0"/>"#
        xml += #"<c:axPos val="\#(valuePosition)"/><c:majorGridlines/>"#
        xml += numberFormat
        xml += #"<c:crossAx val="\#(categoryAxisID)"/></c:valAx>"#
        return xml
    }

    /// One `<c:ser>`, with the child order the schema demands for its chart type.
    private static func series(
        index: Int,
        series: XLSXSeries,
        chart: XLSXChart,
        resolver: some XLSXRangeResolver
    ) -> String {
        var xml = #"<c:ser><c:idx val="\#(index)"/><c:order val="\#(index)"/>"#
        if let nameCell = series.nameCell {
            xml += "<c:tx>" + stringReference(nameCell, resolver: resolver) + "</c:tx>"
        }
        if chart.kind == .line {
            xml += #"<c:marker><c:symbol val="none"/></c:marker>"#
        }
        xml += "<c:cat>" + categoryReference(chart.categories, resolver: resolver) + "</c:cat>"
        xml += "<c:val>" + numberReference(series.values, format: chart.valueNumberFormat, resolver: resolver) + "</c:val>"
        if chart.kind == .line {
            xml += #"<c:smooth val="0"/>"#
        }
        xml += "</c:ser>"
        return xml
    }

    // MARK: - References and caches

    /// A `<c:strRef>` with a one-point cache — used for the series name.
    private static func stringReference(_ range: XLSXRange, resolver: some XLSXRangeResolver) -> String {
        let values = resolver.cells(in: range).map(displayText)
        return #"<c:strRef><c:f>\#(XLSXWriter.escape(range.chartFormula))</c:f>"#
            + stringCache(values)
            + "</c:strRef>"
    }

    /// The category axis reference.
    ///
    /// Dates and numbers go out as a `<c:numRef>` with their format code, text as a `<c:strRef>`. The
    /// decision is taken from the **actual cells**, not from a flag the caller sets, so it cannot drift
    /// away from what is on the sheet — a date column referenced as text would plot raw serials.
    private static func categoryReference(_ range: XLSXRange, resolver: some XLSXRangeResolver) -> String {
        let cells = resolver.cells(in: range)
        let isDate = cells.contains { if case .date = $0 { true } else { false } }
        let isNumeric = isDate || cells.contains { if case .number = $0 { true } else { false } }
        guard isNumeric else {
            return #"<c:strRef><c:f>\#(XLSXWriter.escape(range.chartFormula))</c:f>"#
                + stringCache(cells.map(displayText))
                + "</c:strRef>"
        }
        return #"<c:numRef><c:f>\#(XLSXWriter.escape(range.chartFormula))</c:f>"#
            + numberCache(cells, format: isDate ? "yyyy\\-mm\\-dd" : "General")
            + "</c:numRef>"
    }

    private static func numberReference(
        _ range: XLSXRange,
        format: String?,
        resolver: some XLSXRangeResolver
    ) -> String {
        let cells = resolver.cells(in: range)
        return #"<c:numRef><c:f>\#(XLSXWriter.escape(range.chartFormula))</c:f>"#
            + numberCache(cells, format: format ?? "General")
            + "</c:numRef>"
    }

    /// A `<c:numCache>`. Blank cells are **omitted**, not written as zero — that omission is what
    /// `dispBlanksAs="gap"` acts on.
    private static func numberCache(_ cells: [XLSXCell], format: String) -> String {
        var points = ""
        for (index, cell) in cells.enumerated() {
            let value: Double
            switch cell {
            case let .number(number, _): value = number
            case let .date(date): value = XLSXDateSerial.serial(for: date)
            case .text, .blank: continue
            }
            guard let literal = XLSXWriter.numberLiteral(value) else { continue }
            points += #"<c:pt idx="\#(index)"><c:v>\#(literal)</c:v></c:pt>"#
        }
        return #"<c:numCache><c:formatCode>\#(XLSXWriter.escape(format))</c:formatCode><c:ptCount val="\#(cells.count)"/>"#
            + points
            + "</c:numCache>"
    }

    private static func stringCache(_ values: [String]) -> String {
        var points = ""
        for (index, value) in values.enumerated() where !value.isEmpty {
            points += #"<c:pt idx="\#(index)"><c:v>\#(XLSXWriter.escape(value))</c:v></c:pt>"#
        }
        return #"<c:strCache><c:ptCount val="\#(values.count)"/>"# + points + "</c:strCache>"
    }

    /// How a cell reads as a chart label.
    private static func displayText(_ cell: XLSXCell) -> String {
        switch cell {
        case let .text(value, _): value
        case let .number(value, _): XLSXWriter.numberLiteral(value) ?? ""
        case let .date(value): Self.isoDay(value)
        case .blank: ""
        }
    }

    /// `yyyy-MM-dd` in UTC, computed rather than formatted.
    ///
    /// A cached `ISO8601DateFormatter` would be a mutable global under Swift 6 strict concurrency, and
    /// a fresh one per call would be wasteful for something this small. The civil-from-days arithmetic
    /// is also immune to the locale and calendar settings of whoever runs the export.
    private static func isoDay(_ date: Date) -> String {
        var days = Int(floor(date.timeIntervalSince1970 / 86_400))
        days += 719_468 // shift the epoch to 0000-03-01, which makes leap years periodic
        let era = (days >= 0 ? days : days - 146_096) / 146_097
        let dayOfEra = days - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let year = yearOfEra + era * 400
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
        let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
        let calendarYear = month <= 2 ? year + 1 : year
        return String(format: "%04d-%02d-%02d", calendarYear, month, day)
    }

    // MARK: - drawingN.xml

    /// The drawing part: one two-cell anchor per chart on the sheet.
    static func drawing(_ charts: [XLSXWriter.ChartPlan]) -> String {
        var xml = XLSXWriter.xmlHeader
        xml += #"<xdr:wsDr xmlns:xdr="http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">"#
        for (index, plan) in charts.enumerated() {
            let anchor = plan.chart.anchor
            xml += "<xdr:twoCellAnchor>"
            xml += "<xdr:from><xdr:col>\(anchor.fromColumn)</xdr:col><xdr:colOff>0</xdr:colOff>"
            xml += "<xdr:row>\(anchor.fromRow)</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:from>"
            xml += "<xdr:to><xdr:col>\(anchor.toColumn)</xdr:col><xdr:colOff>0</xdr:colOff>"
            xml += "<xdr:row>\(anchor.toRow)</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:to>"
            xml += "<xdr:graphicFrame><xdr:nvGraphicFramePr>"
            // The shape id must be unique within the drawing; 1 is conventionally reserved.
            xml += #"<xdr:cNvPr id="\#(index + 2)" name="Chart \#(index + 1)"/><xdr:cNvGraphicFramePr/>"#
            xml += "</xdr:nvGraphicFramePr>"
            xml += #"<xdr:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/></xdr:xfrm>"#
            xml += #"<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/chart">"#
            xml += #"<c:chart xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" r:id="\#(plan.relationshipID)"/>"#
            xml += "</a:graphicData></a:graphic></xdr:graphicFrame>"
            xml += "<xdr:clientData/></xdr:twoCellAnchor>"
        }
        xml += "</xdr:wsDr>"
        return xml
    }
}
