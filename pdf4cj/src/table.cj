package pdf4cj

import std.collection.*
import std.sort.*

/**
 * Ruled-table detection over the objects the content layer already extracted.
 *
 * Only tables drawn with rules are found (pdfplumber's default strategy): the
 * grids come from rectangle edges and from horizontal/vertical lines, never from
 * whitespace alignment. A table is reported only when a closed grid of at least
 * two vertical and two horizontal lines encloses at least two cells (pdfplumber
 * discards single-cell groups), so ordinary underlines, page frames and lone
 * filled boxes stay out.
 *
 * The algorithm follows pdfplumber's `TableFinder` in four steps:
 *
 * 1. **Edges.** Each [RectObj] contributes four edges, each [LineObj] one; lines
 *    that are neither horizontal nor vertical (within [TABLE_STRAIGHT_TOLERANCE])
 *    are ignored, as are edges shorter than [TABLE_MIN_EDGE_LENGTH].
 * 2. **Snapping and merging.** Edges are sorted by their fixed coordinate and
 *    clustered with [TABLE_SNAP_TOLERANCE] (pdfplumber's `snap_tolerance`); each
 *    cluster collapses to one coordinate, and overlapping edges inside it merge
 *    into the longest run.
 * 3. **Connected components.** Two edges belong to the same table when they
 *    cross, so a frame plus its inner rules merge into one table while two
 *    separate grids stay apart.
 * 4. **Cells.** For every x interval and every y interval of a component the four
 *    borders must all be covered by an edge; the surviving rectangles become the
 *    cells, filled with the characters whose centre falls inside.
 *
 * Coordinates: edges and cells are computed in PDF user space (y upwards);
 * the returned [TableObj] uses pdfplumber's top-based `y0`/`y1`.
 */

/** Coordinate clustering tolerance, in the middle of pdfplumber's 2.0-3.0 range. */
let TABLE_SNAP_TOLERANCE: Float64 = 2.5

/** Edges shorter than this are noise (rounding, stray markers) and are dropped. */
let TABLE_MIN_EDGE_LENGTH: Float64 = 3.0

/** A line counts as horizontal/vertical when its two ends differ less than this. */
let TABLE_STRAIGHT_TOLERANCE: Float64 = 0.5

/** Maximum baseline/`y0` difference for two characters to share a text row. */
let TABLE_TEXT_Y_TOLERANCE: Float64 = 2.0

/** Horizontal gap that becomes a space when glyph boxes already carry spaces. */
let TABLE_TEXT_X_GAP: Float64 = 1.5

/**
 * Upper bound on the merged edges one page may contribute.
 *
 * Component grouping is quadratic in the edge count, so a page of vector art
 * (charts, maps, CAD output) that happens to be made of thousands of rules would
 * otherwise dominate the extraction time. A real table - the largest grids are a
 * few hundred rules - stays far below this; the limit is reported as a known
 * limitation rather than silently mis-detecting.
 */
let TABLE_MAX_EDGES: Int64 = 4000

/** Upper bound on the cells examined per connected component (158x158 grid). */
let TABLE_MAX_CELLS: Int64 = 25000

/**
 * One straight grid edge.
 *
 * `horizontal` edges run left-to-right at `fixed` = y with `start`/`end` as x;
 * vertical edges run bottom-to-top at `fixed` = x with `start`/`end` as y.
 * `start` is always the smaller coordinate.
 */
class TableEdge {
    let horizontal: Bool
    var fixed: Float64
    var start: Float64
    var end: Float64

    init(horizontal: Bool, fixed: Float64, start: Float64, end: Float64) {
        this.horizontal = horizontal
        this.fixed = fixed
        this.start = if (start <= end) { start } else { end }
        this.end = if (start <= end) { end } else { start }
    }

    func length(): Float64 {
        this.end - this.start
    }

    /** Whether this edge spans `[from, to]`, allowing `tolerance` of slack. */
    func covers(from: Float64, to: Float64, tolerance: Float64): Bool {
        this.start <= from + tolerance && this.end >= to - tolerance
    }
}

/** One candidate cell of a component grid, still in PDF user space. */
class TableCellBox {
    let x0: Float64
    let y0: Float64
    let x1: Float64
    let y1: Float64

    init(x0: Float64, y0: Float64, x1: Float64, y1: Float64) {
        this.x0 = x0
        this.y0 = y0
        this.x1 = x1
        this.y1 = y1
    }
}

/**
 * Detect ruled tables on `page` from the `data` already extracted for it.
 *
 * The returned tables are ordered top-to-bottom and, for equal tops,
 * left-to-right, matching pdfplumber's `page.find_tables()` ordering. `data` is
 * not modified; the caller decides where to store the result.
 */
public func extractTables(page: PdfPage, data: PageData): ArrayList<TableObj> {
    let tables = ArrayList<TableObj>()
    let edges = tableMergeEdges(tableCollectEdges(data))
    if (edges.size < 4 || edges.size > TABLE_MAX_EDGES) {
        return tables
    }
    let pageHeight = page.height
    let pageNumber = page.number
    for (component in tableComponents(edges)) {
        match (tableComponentToTable(component, data.chars, pageHeight, pageNumber)) {
            case Some(table) => tables.add(table)
            case None => ()
        }
    }
    sort<TableObj>(
        tables,
        lessThan: {
            left: TableObj, right: TableObj =>
            if (left.y0 != right.y0) {
                left.y0 < right.y0
            } else {
                left.x0 < right.x0
            }
        },
        stable: true
    )
    tables
}

// ---------------------------------------------------------------------------
// Step 1: edges

/** Collect all horizontal/vertical edges contributed by rects and lines. */
func tableCollectEdges(data: PageData): ArrayList<TableEdge> {
    let edges = ArrayList<TableEdge>()
    for (rect in data.rects) {
        let minX = tableMin(rect.x0, rect.x1)
        let maxX = tableMax(rect.x0, rect.x1)
        let minY = tableMin(rect.y0, rect.y1)
        let maxY = tableMax(rect.y0, rect.y1)
        edges.add(TableEdge(true, minY, minX, maxX))
        edges.add(TableEdge(true, maxY, minX, maxX))
        edges.add(TableEdge(false, minX, minY, maxY))
        edges.add(TableEdge(false, maxX, minY, maxY))
    }
    for (line in data.lines) {
        let dy = tableAbs(line.y1 - line.y0)
        let dx = tableAbs(line.x1 - line.x0)
        if (dy <= TABLE_STRAIGHT_TOLERANCE) {
            edges.add(TableEdge(true, (line.y0 + line.y1) / 2.0, line.x0, line.x1))
        } else if (dx <= TABLE_STRAIGHT_TOLERANCE) {
            edges.add(TableEdge(false, (line.x0 + line.x1) / 2.0, line.y0, line.y1))
        }
        // Slanted lines carry no axis-aligned grid information.
    }
    let kept = ArrayList<TableEdge>()
    for (edge in edges) {
        if (edge.length() >= TABLE_MIN_EDGE_LENGTH) {
            kept.add(edge)
        }
    }
    kept
}

// ---------------------------------------------------------------------------
// Step 2: snapping + merging

/**
 * Cluster edges onto shared coordinates and merge the overlapping ones.
 *
 * Two passes: first every orientation is sorted by its fixed coordinate and
 * snapped to the first coordinate of its cluster (so a chain of slightly
 * different rules collapses instead of drifting), then the intervals inside a
 * cluster are unioned when they overlap or touch within the tolerance.
 */
func tableMergeEdges(edges: ArrayList<TableEdge>): ArrayList<TableEdge> {
    let merged = ArrayList<TableEdge>()
    for (horizontal in [true, false]) {
        let oriented = ArrayList<TableEdge>()
        for (edge in edges) {
            if (edge.horizontal == horizontal) {
                oriented.add(edge)
            }
        }
        sort<TableEdge>(
            oriented,
            lessThan: {
                left: TableEdge, right: TableEdge =>
                if (left.fixed != right.fixed) {
                    left.fixed < right.fixed
                } else {
                    left.start < right.start
                }
            },
            stable: true
        )
        var cluster = ArrayList<TableEdge>()
        var anchor: Float64 = 0.0
        for (edge in oriented) {
            if (cluster.isEmpty() || edge.fixed - anchor > TABLE_SNAP_TOLERANCE) {
                tableFlushCluster(cluster, merged)
                cluster = ArrayList<TableEdge>()
                anchor = edge.fixed
            }
            cluster.add(TableEdge(horizontal, anchor, edge.start, edge.end))
        }
        tableFlushCluster(cluster, merged)
    }
    merged
}

/** Merge one cluster's intervals and append the results to `out`. */
func tableFlushCluster(cluster: ArrayList<TableEdge>, out: ArrayList<TableEdge>): Unit {
    if (cluster.isEmpty()) {
        return
    }
    sort<TableEdge>(
        cluster,
        lessThan: {
            left: TableEdge, right: TableEdge => left.start < right.start
        },
        stable: true
    )
    var current = cluster[0]
    for (i in 1..cluster.size) {
        let next = cluster[i]
        if (next.start <= current.end + TABLE_SNAP_TOLERANCE) {
            current.end = tableMax(current.end, next.end)
        } else {
            out.add(current)
            current = next
        }
    }
    out.add(current)
}

// ---------------------------------------------------------------------------
// Step 3: connected components

/** Whether a horizontal and a vertical edge of the grid touch each other. */
func tableEdgesCross(left: TableEdge, right: TableEdge): Bool {
    if (left.horizontal == right.horizontal) {
        // Parallel edges of the same orientation never connect; collinear ones
        // were already merged in the snapping pass.
        return false
    }
    let horizontalEdge = if (left.horizontal) { left } else { right }
    let verticalEdge = if (left.horizontal) { right } else { left }
    horizontalEdge.covers(verticalEdge.fixed, verticalEdge.fixed, TABLE_SNAP_TOLERANCE) &&
        verticalEdge.covers(horizontalEdge.fixed, horizontalEdge.fixed, TABLE_SNAP_TOLERANCE)
}

/**
 * Split the merged edges into connected groups, one per table.
 *
 * Uses a union-find over edge indices: everything reachable through crossings
 * (frame + inner rules) lands in the same group, while disjoint grids do not.
 * Groups keep the order of their first edge so the output stays deterministic.
 */
func tableComponents(edges: ArrayList<TableEdge>): ArrayList<ArrayList<TableEdge>> {
    let parent = ArrayList<Int64>(edges.size)
    for (i in 0..edges.size) {
        parent.add(i)
    }
    for (i in 0..edges.size) {
        for (j in (i + 1)..edges.size) {
            if (tableEdgesCross(edges[i], edges[j])) {
                tableUnion(parent, i, j)
            }
        }
    }
    let order = ArrayList<Int64>()
    let groups = HashMap<Int64, ArrayList<TableEdge>>()
    for (i in 0..edges.size) {
        let root = tableFind(parent, i)
        match (groups.get(root)) {
            case Some(group) => group.add(edges[i])
            case None =>
                let group = ArrayList<TableEdge>()
                group.add(edges[i])
                groups.add(root, group)
                order.add(root)
        }
    }
    let components = ArrayList<ArrayList<TableEdge>>()
    for (root in order) {
        match (groups.get(root)) {
            case Some(group) => components.add(group)
            case None => ()
        }
    }
    components
}

func tableFind(parent: ArrayList<Int64>, index: Int64): Int64 {
    var current = index
    while (parent[current] != current) {
        parent[current] = parent[parent[current]]
        current = parent[current]
    }
    current
}

func tableUnion(parent: ArrayList<Int64>, left: Int64, right: Int64): Unit {
    let leftRoot = tableFind(parent, left)
    let rightRoot = tableFind(parent, right)
    if (leftRoot != rightRoot) {
        parent[rightRoot] = leftRoot
    }
}

// ---------------------------------------------------------------------------
// Step 4: cells

/** Sorted unique coordinates along one axis, plus the index range they bound. */
class TableAxis {
    let values: ArrayList<Float64>

    init(values: ArrayList<Float64>) {
        this.values = values
    }

    func intervalCount(): Int64 {
        if (this.values.size < 2) {
            0
        } else {
            this.values.size - 1
        }
    }
}

func tableAxisOf(component: ArrayList<TableEdge>, horizontal: Bool): TableAxis {
    let values = ArrayList<Float64>()
    for (edge in component) {
        if (edge.horizontal == horizontal) {
            var duplicate = false
            for (existing in values) {
                if (tableAbs(existing - edge.fixed) <= TABLE_SNAP_TOLERANCE) {
                    duplicate = true
                    break
                }
            }
            if (!duplicate) {
                values.add(edge.fixed)
            }
        }
    }
    sort<Float64>(values, stable: true)
    TableAxis(values)
}

/** Whether `component` has an edge of the given orientation on `fixed` spanning the range. */
func tableHasEdge(
    component: ArrayList<TableEdge>,
    horizontal: Bool,
    fixed: Float64,
    from: Float64,
    to: Float64
): Bool {
    for (edge in component) {
        if (edge.horizontal == horizontal &&
            tableAbs(edge.fixed - fixed) <= TABLE_SNAP_TOLERANCE &&
            edge.covers(from, to, TABLE_SNAP_TOLERANCE)) {
            return true
        }
    }
    false
}

/**
 * Turn one connected component into a [TableObj], or `None` when it does not
 * enclose a single closed cell.
 *
 * Rows and columns are the intervals that actually contain a cell, so a stray
 * rule extending past a grid does not add an empty row or column.
 */
func tableComponentToTable(
    component: ArrayList<TableEdge>,
    chars: ArrayList<CharObj>,
    pageHeight: Float64,
    pageNumber: Int64
): Option<TableObj> {
    let xs = tableAxisOf(component, false)
    let ys = tableAxisOf(component, true)
    let cols = xs.intervalCount()
    let rows = ys.intervalCount()
    if (cols < 1 || rows < 1) {
        return None
    }
    if (cols * rows > TABLE_MAX_CELLS) {
        // A grid this large is vector art, not a table of text.
        return None
    }
    // valid[row][col]: all four borders of that rectangle are drawn. The rows are
    // allocated one by one: `repeat:` would alias the same inner array.
    let valid = ArrayList<ArrayList<Bool>>(rows)
    for (_ in 0..rows) {
        valid.add(ArrayList<Bool>(cols, {_ => false}))
    }
    for (row in 0..rows) {
        let yLow = ys.values[row]
        let yHigh = ys.values[row + 1]
        for (col in 0..cols) {
            let xLeft = xs.values[col]
            let xRight = xs.values[col + 1]
            let closed = tableHasEdge(component, true, yLow, xLeft, xRight) &&
                tableHasEdge(component, true, yHigh, xLeft, xRight) &&
                tableHasEdge(component, false, xLeft, yLow, yHigh) &&
                tableHasEdge(component, false, xRight, yLow, yHigh)
            valid[row][col] = closed
        }
    }
    // Keep only the intervals that carry at least one cell, rows top-most first:
    // the y axis is sorted ascending (PDF space), so the highest interval is the
    // first row of the table.
    let usedRows = ArrayList<Int64>()
    for (offset in 0..rows) {
        let row = rows - 1 - offset
        for (col in 0..cols) {
            if (valid[row][col]) {
                usedRows.add(row)
                break
            }
        }
    }
    let usedCols = ArrayList<Int64>()
    for (col in 0..cols) {
        for (row in 0..rows) {
            if (valid[row][col]) {
                usedCols.add(col)
                break
            }
        }
    }
    if (usedRows.isEmpty() || usedCols.isEmpty()) {
        return None
    }
    // pdfplumber drops single-cell groups (`len(t) > 1` in `cells_to_tables`), and
    // matching that keeps a lone filled box - a highlight, a coloured header, an
    // image frame - from being reported as a one-cell "table".
    var cellCount = 0
    for (row in 0..rows) {
        for (col in 0..cols) {
            if (valid[row][col]) {
                cellCount += 1
            }
        }
    }
    if (cellCount < 2) {
        return None
    }
    // Built row by row for the same aliasing reason as `valid`, then frozen into
    // the `Array<Array<String>>` the data model expects.
    let rowsOut = ArrayList<Array<String>>(usedRows.size)
    for (_ in 0..usedRows.size) {
        rowsOut.add(Array<String>(usedCols.size, repeat: ""))
    }
    let cells = rowsOut.toArray()
    var minX: Float64 = 0.0
    var maxX: Float64 = 0.0
    var minY: Float64 = 0.0
    var maxY: Float64 = 0.0
    var first = true
    for (rowIndex in 0..usedRows.size) {
        let row = usedRows[rowIndex]
        let yLow = ys.values[row]
        let yHigh = ys.values[row + 1]
        for (colIndex in 0..usedCols.size) {
            let col = usedCols[colIndex]
            if (!valid[row][col]) {
                continue
            }
            let xLeft = xs.values[col]
            let xRight = xs.values[col + 1]
            cells[rowIndex][colIndex] = tableCellText(chars, TableCellBox(xLeft, yLow, xRight, yHigh))
            if (first) {
                minX = xLeft
                maxX = xRight
                minY = yLow
                maxY = yHigh
                first = false
            } else {
                minX = tableMin(minX, xLeft)
                maxX = tableMax(maxX, xRight)
                minY = tableMin(minY, yLow)
                maxY = tableMax(maxY, yHigh)
            }
        }
    }
    if (first) {
        return None
    }
    Some(
        TableObj(
            x0: minX,
            y0: pageHeight - maxY,
            x1: maxX,
            y1: pageHeight - minY,
            rows: usedRows.size,
            cols: usedCols.size,
            cells: cells,
            page: pageNumber
        )
    )
}

// ---------------------------------------------------------------------------
// Cell text

/**
 * Text of one cell: characters whose centre falls inside the box, read top to
 * bottom and left to right, one `\n`-separated line per visual row.
 *
 * A glyph that is only whitespace separates words instead of contributing
 * itself, and a horizontal gap wider than [TABLE_TEXT_X_GAP] also yields one
 * space, so "Header A" survives either way the content layer reports spaces.
 */
func tableCellText(chars: ArrayList<CharObj>, box: TableCellBox): String {
    let inside = ArrayList<CharObj>()
    for (char in chars) {
        let centerX = (char.x0 + char.x1) / 2.0
        let centerY = (char.y0 + char.y1) / 2.0
        if (centerX >= box.x0 && centerX <= box.x1 && centerY >= box.y0 && centerY <= box.y1) {
            inside.add(char)
        }
    }
    if (inside.isEmpty()) {
        return ""
    }
    sort<CharObj>(
        inside,
        lessThan: {
            left: CharObj, right: CharObj =>
            if (tableAbs(left.y0 - right.y0) > TABLE_TEXT_Y_TOLERANCE) {
                left.y0 > right.y0
            } else {
                left.x0 < right.x0
            }
        },
        stable: true
    )
    let text = StringBuilder()
    var lineAnchor = inside[0].y0
    var lineStarted = false
    var pendingSpace = false
    var lastX1 = 0.0
    for (char in inside) {
        if (tableAbs(char.y0 - lineAnchor) > TABLE_TEXT_Y_TOLERANCE) {
            if (lineStarted) {
                text.append("\n")
            }
            lineAnchor = char.y0
            lineStarted = false
            pendingSpace = false
        }
        if (tableIsBlankText(char.text)) {
            pendingSpace = lineStarted
            continue
        }
        if (lineStarted) {
            let gap = char.x0 - lastX1
            if (pendingSpace || gap > TABLE_TEXT_X_GAP) {
                text.append(" ")
            }
        } else {
            lineStarted = true
        }
        text.append(char.text)
        lastX1 = char.x1
        pendingSpace = false
    }
    text.toString()
}

func tableIsBlankText(text: String): Bool {
    match (text) {
        case " " | "\t" | "\n" | "\r" | "\u{000B}" | "\u{000C}" => true
        case _ => false
    }
}

// ---------------------------------------------------------------------------
// Small numeric helpers

func tableMin(left: Float64, right: Float64): Float64 {
    if (left <= right) { left } else { right }
}

func tableMax(left: Float64, right: Float64): Float64 {
    if (left >= right) { left } else { right }
}

func tableAbs(value: Float64): Float64 {
    if (value < 0.0) { -value } else { value }
}
