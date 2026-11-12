package pdf_inspector_mcp.export

import std.collection.*

/**
 * Object-type selection for the export layer.
 *
 * Mirror of `pdf_inspector_mcp.objects.EXPORT_OBJECT_TYPES` /
 * `export.resolve_types`: the seven exported object kinds in the canonical
 * order both the JSON and the CSV renderer rely on (CSV section order, JSON
 * `objectTypes` array order, page object key order).
 */
public let EXPORT_OBJECT_TYPES: Array<String> = ["char", "word", "rect", "line", "curve", "image", "table"]

/**
 * Canonical, de-duplicated type selection.
 *
 * `None` means "every type"; an explicit empty array stays empty (it means
 * "no object data", not "all"). Unknown type strings are ignored instead of
 * being rejected, duplicates collapse, and the result is always in canonical
 * `EXPORT_OBJECT_TYPES` order rather than caller order.
 */
public func resolveTypes(types: Option<Array<String>>): Array<String> {
    let resolved = ArrayList<String>()
    match (types) {
        case None =>
            for (typeName in EXPORT_OBJECT_TYPES) {
                resolved.add(typeName)
            }
        case Some(requested) =>
            for (typeName in EXPORT_OBJECT_TYPES) {
                if (isSelected(requested, typeName)) {
                    resolved.add(typeName)
                }
            }
    }
    return resolved.toArray()
}

/** Membership test over an already-resolved selection (package internal). */
func isSelected(selected: Array<String>, typeName: String): Bool {
    for (candidate in selected) {
        if (candidate == typeName) {
            return true
        }
    }
    return false
}
