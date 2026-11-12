package pdf_inspector_mcp.mcp

import magic.core.tool.{Tool, ToolException, ToolParameter, ToolResponse}

import std.collection.{ArrayList, HashMap}
import std.env.{ConsoleReader, ConsoleWriter, getStdIn, getStdOut}
import stdx.encoding.json.*

/**
 * Minimal MCP server over the stdio transport.
 *
 * CangjieMagic's own `StdioMCPServer` is deliberately not used: it marks every
 * parameter as required in `tools/list` (it ignores `Option`), lets an exception
 * thrown by a tool kill the whole loop, and always answers `isError: false`.
 * This implementation owns the JSON-RPC loop instead and only reuses the
 * `@tool` functions and the `magic.core.tool.Tool` interface.
 *
 * The wire shape is the MCP one, not CangjieMagic's internal one: a tool is
 * advertised as `{name, description, inputSchema}` (see `buildToolsListResult`),
 * and `initialize` only echoes a `protocolVersion` it can actually speak.
 *
 * Wire format: one JSON-RPC 2.0 message per line on stdin, one response per
 * line on stdout (always flushed). Diagnostics go to stderr only.
 */

private let JSONRPC_VERSION = "2.0"
private let DEFAULT_PROTOCOL_VERSION = "2024-11-05"

/**
 * Protocol revisions this server implements. Anything else - older drafts and
 * versions newer than the build - is answered with `DEFAULT_PROTOCOL_VERSION`,
 * which is what the specification asks a server to do when it cannot speak the
 * client's revision (the client then decides whether to continue or disconnect).
 */
private let SUPPORTED_PROTOCOL_VERSIONS: Array<String> = ["2024-11-05", "2025-06-18"]
private let SERVER_NAME = "pdf-inspector"
private let SERVER_VERSION = "0.1.0-cangjie"

// JSON-RPC 2.0 error codes.
private let PARSE_ERROR = -32700
private let INVALID_REQUEST = -32600
private let METHOD_NOT_FOUND = -32601
private let INVALID_PARAMS = -32602
private let INTERNAL_ERROR = -32603

/**
 * The registered tools. `tools/list` is built from `Tool.parameters`, which the
 * `@tool` macro derives from the function signature: `ToolParameter.required`
 * comes from `Option<T>`, so optional arguments are not advertised as required.
 */
private let SERVER_TOOLS: Array<Tool> = [
    pdf_get_metadata,
    pdf_extract_page,
    pdf_extract_document,
    pdf_analyze_fonts,
    pdf_get_image,
    pdf_export
]

/**
 * Serialise a JSON value as a single line. stdx only pretty-prints, and the
 * stdio transport requires one message per line. Pretty printing never puts a
 * raw newline inside a string literal (they are escaped), so trimming each line
 * and joining the pieces is lossless.
 */
private func toCompactJson(value: JsonValue): String {
    let parts = ArrayList<String>()
    for (line in value.toJsonString().split("\n")) {
        let trimmed = line.trimAscii()
        if (!trimmed.isEmpty()) {
            parts.add(trimmed)
        }
    }
    return String.join(parts.toArray(), delimiter: "")
}

private func readString(object: JsonObject, key: String): Option<String> {
    if (let Some(value) <- object.get(key)) {
        match (value.kind()) {
            case JsonKind.JsString => return Some(value.asString().getValue())
            case _ => return None
        }
    }
    return None
}

private func readObject(object: JsonObject, key: String): Option<JsonObject> {
    if (let Some(value) <- object.get(key)) {
        match (value.kind()) {
            case JsonKind.JsObject => return Some(value.asObject())
            case _ => return None
        }
    }
    return None
}

private func buildSuccess(id: Option<JsonValue>, result: JsonValue): JsonObject {
    let response = JsonObject()
    response.put("jsonrpc", JsonString(JSONRPC_VERSION))
    response.put("id", id ?? JsonNull())
    response.put("result", result)
    return response
}

private func buildError(id: Option<JsonValue>, code: Int64, message: String): JsonObject {
    let error = JsonObject()
    error.put("code", JsonInt(code))
    error.put("message", JsonString(message))

    let response = JsonObject()
    response.put("jsonrpc", JsonString(JSONRPC_VERSION))
    response.put("id", id ?? JsonNull())
    response.put("error", error)
    return response
}

private func buildInitializeResult(params: Option<JsonObject>): JsonValue {
    let protocolVersion = negotiateProtocolVersion(params)

    let toolsCapability = JsonObject()
    toolsCapability.put("listChanged", JsonBool(false))
    let capabilities = JsonObject()
    capabilities.put("tools", toolsCapability)

    let serverInfo = JsonObject()
    serverInfo.put("name", JsonString(SERVER_NAME))
    serverInfo.put("version", JsonString(SERVER_VERSION))

    let result = JsonObject()
    result.put("protocolVersion", JsonString(protocolVersion))
    result.put("capabilities", capabilities)
    result.put("serverInfo", serverInfo)
    return result
}

/**
 * Echo the client's revision when it is one this server implements, otherwise
 * answer with `DEFAULT_PROTOCOL_VERSION`.
 *
 * Echoing *any* string would be a silent lie: a client that asked for a future
 * revision would believe the server speaks it, while the messages on the wire
 * are still 2024-11-05 shaped.
 */
private func negotiateProtocolVersion(params: Option<JsonObject>): String {
    if (let Some(paramsObject) <- params) {
        if (let Some(requested) <- readString(paramsObject, "protocolVersion")) {
            for (candidate in SUPPORTED_PROTOCOL_VERSIONS) {
                if (candidate == requested) {
                    return candidate
                }
            }
        }
    }
    return DEFAULT_PROTOCOL_VERSION
}

/**
 * The `tools/list` payload in the shape MCP clients parse:
 * `{name, description, inputSchema}`.
 *
 * `Tool.toJsonValue()` is CangjieMagic's *internal* shape - it nests the JSON
 * schema of the arguments under `parameters` and may add `examples`/`retType` -
 * which the MCP specification does not define, so a client built on the official
 * SDK rejects the response (`tools.0.inputSchema Field required`). The schema
 * itself is worth keeping: it is where `required` and the per-argument
 * descriptions live, so it is moved to `inputSchema` (with the optional
 * arguments made nullable, see `nullableInputSchema`) instead of being rebuilt.
 */
private func buildToolsListResult(tools: Array<Tool>): JsonValue {
    let items = ArrayList<JsonValue>()
    for (tool in tools) {
        let internal = tool.toJsonValue().asObject()
        let rawSchema = match (internal.get("parameters")) {
            case Some(value) => value
            case None => emptyObjectSchema()
        }
        let item = JsonObject()
        item.put("name", JsonString(tool.name))
        if (!tool.description.isEmpty()) {
            item.put("description", JsonString(tool.description))
        }
        item.put("inputSchema", nullableInputSchema(tool, rawSchema))
        items.add(item)
    }
    let result = JsonObject()
    result.put("tools", JsonArray(items.toArray()))
    return result
}

/**
 * Arguments whose Python counterpart really is `Optional[...] = None`, i.e. where
 * "omitted" and "null" mean the same thing. Only these get `default: null`;
 * `format` and `scope` are optional in the Cangjie signature only because the
 * `@tool` macro maps every defaulted argument to `Option<T>`, and their meaning
 * when omitted is `json`/`document`, not null.
 */
private let OPTIONAL_WITH_NULL_DEFAULT: Array<String> = [
    "password", "page", "first_page", "last_page", "start_page", "end_page", "output_path"
]

/**
 * `inputSchema` with every `Option<T>` argument marked nullable.
 *
 * `ToolParameter.required` is false exactly for the `Option<T>` parameters, and
 * the macro describes them with the bare non-null type (`{"type": "string"}`).
 * The server accepts `null` for them (`Option<T>.fromJsonValue(JsonNull)` is
 * `None`), so advertising a non-nullable type is a wire-level lie that a strict
 * JSON-Schema client turns into a client-side validation error before the call
 * is ever sent. Each optional property is therefore wrapped the way pydantic
 * describes `Optional[T] = None`: `{"anyOf": [<original schema>,
 * {"type": "null"}]}`, which keeps `type`, `items` and `description` inside the
 * first alternative.
 *
 * The property order follows the declaration order (which is also `required`'s
 * order) and the rest of the schema object - `type`, `required` - is copied
 * through untouched, so this only ever changes the optional entries.
 */
private func nullableInputSchema(tool: Tool, schema: JsonValue): JsonValue {
    let schemaObject = schema.asObject()
    let properties = match (schemaObject.get("properties")) {
        case Some(value) => value.asObject()
        case None => return schema
    }
    let updated = JsonObject()
    for (parameter in tool.parameters) {
        let original = match (properties.get(parameter.name)) {
            case Some(value) => value
            case None => continue
        }
        if (parameter.required) {
            updated.put(parameter.name, original)
        } else {
            updated.put(parameter.name, nullableParameterSchema(parameter.name, original))
        }
    }
    let rebuilt = JsonObject()
    for ((name, value) in schemaObject.getFields()) {
        if (name != "properties") {
            rebuilt.put(name, value)
        }
    }
    rebuilt.put("properties", updated)
    return rebuilt
}

/** `{"anyOf": [schema, {"type": "null"}]}`, plus `default: null` where that is the truth. */
private func nullableParameterSchema(name: String, schema: JsonValue): JsonValue {
    let alternatives = ArrayList<JsonValue>()
    alternatives.add(schema)
    let nullAlternative = JsonObject()
    nullAlternative.put("type", JsonString("null"))
    alternatives.add(nullAlternative)

    let wrapped = JsonObject()
    wrapped.put("anyOf", JsonArray(alternatives.toArray()))
    if (isNullDefaultParameter(name)) {
        wrapped.put("default", JsonNull())
    }
    return wrapped
}

private func isNullDefaultParameter(name: String): Bool {
    for (candidate in OPTIONAL_WITH_NULL_DEFAULT) {
        if (candidate == name) {
            return true
        }
    }
    return false
}

/** `{"type": "object", "properties": {}, "required": []}` - the schema for no arguments. */
private func emptyObjectSchema(): JsonValue {
    let schema = JsonObject()
    schema.put("type", JsonString("object"))
    schema.put("properties", JsonObject())
    schema.put("required", JsonArray(Array<JsonValue>()))
    return schema
}

private func findTool(tools: Array<Tool>, name: String): Option<Tool> {
    for (tool in tools) {
        if (tool.name == name) {
            return Some(tool)
        }
    }
    return None
}

/**
 * Log a failure to stderr. Only `message` is printed: this toolchain's runtime
 * crashes when `toString()` is dynamically dispatched on exception classes, so
 * `e.toString()` (and therefore the stack trace) is unusable here.
 */
private func logFailure(context: String, error: Exception): Unit {
    eprintln("pdf-inspector-mcp: " + context + ": " + error.message)
}

/**
 * Invoke `tool`, turning every failure into a `ToolResponse` so that a single
 * bad call can never terminate the server loop or leak a stack trace.
 */
private func invokeTool(tool: Tool, arguments: HashMap<String, JsonValue>): ToolResponse {
    try {
        return tool.invoke(arguments)
    } catch (error: PdfToolError) {
        return ToolResponse(error.message, isError: true)
    } catch (error: ToolException) {
        return ToolResponse(error.message, isError: true)
    } catch (error: Exception) {
        logFailure("tool '" + tool.name + "' failed", error)
        return ToolResponse("Internal error while executing tool '" + tool.name + "'.", isError: true)
    }
}

private func buildToolCallResult(response: ToolResponse): JsonValue {
    let text = JsonObject()
    text.put("type", JsonString("text"))
    text.put("text", JsonString(response.content))
    let content = ArrayList<JsonValue>()
    content.add(text)

    let result = JsonObject()
    result.put("content", JsonArray(content.toArray()))
    result.put("isError", JsonBool(response.isError))
    return result
}

private func handleToolCall(
    id: Option<JsonValue>,
    params: Option<JsonObject>,
    tools: Array<Tool>
): JsonObject {
    var toolName = ""
    var arguments = HashMap<String, JsonValue>()
    if (let Some(paramsObject) <- params) {
        if (let Some(name) <- readString(paramsObject, "name")) {
            toolName = name
        }
        if (let Some(argumentsObject) <- readObject(paramsObject, "arguments")) {
            arguments = argumentsObject.getFields()
        }
    }

    let tool = match (findTool(tools, toolName)) {
        case Some(found) => found
        case None => return buildError(id, INVALID_PARAMS, "Unknown tool: '" + toolName + "'")
    }
    let response = invokeTool(tool, arguments)
    return buildSuccess(id, buildToolCallResult(response))
}

/**
 * Handle one decoded message. Returns `None` for notifications, which must not
 * be answered.
 */
private func dispatch(message: String, tools: Array<Tool>): Option<JsonObject> {
    let parsed = try {
        JsonValue.fromStr(message)
    } catch (error: Exception) {
        logFailure("cannot parse incoming message", error)
        return Some(buildError(None, PARSE_ERROR, "Parse error"))
    }
    let request = match (parsed.kind()) {
        case JsonKind.JsObject => parsed.asObject()
        case _ => return Some(buildError(None, INVALID_REQUEST, "Invalid Request: expected a JSON object"))
    }
    let id = request.get("id")
    let method = match (readString(request, "method")) {
        case Some(name) => name
        case None => return Some(buildError(id, INVALID_REQUEST, "Invalid Request: missing string 'method'"))
    }

    // Notifications must never be answered.
    if (method.startsWith("notifications/")) {
        return None
    }
    let hasId = match (id) {
        case Some(_) => true
        case None => false
    }
    if (!hasId) {
        return None
    }

    let params = readObject(request, "params")
    let response = match (method) {
        case "initialize" => buildSuccess(id, buildInitializeResult(params))
        case "ping" => buildSuccess(id, JsonObject())
        case "tools/list" => buildSuccess(id, buildToolsListResult(tools))
        case "tools/call" => handleToolCall(id, params, tools)
        case _ => buildError(id, METHOD_NOT_FOUND, "Method not found: '" + method + "'")
    }
    return Some(response)
}

/**
 * Serve MCP over stdio until stdin is closed. Never throws: a malformed or
 * failing message is answered (or logged) and the loop continues.
 */
public func runServer(): Unit {
    let reader: ConsoleReader = getStdIn()
    let writer: ConsoleWriter = getStdOut()
    eprintln("pdf-inspector-mcp " + SERVER_VERSION + ": stdio JSON-RPC server ready, "
        + SERVER_TOOLS.size.toString() + " tools registered")

    while (let Some(line) <- reader.readln()) {
        let message = line.trimAscii()
        if (message.isEmpty()) {
            continue
        }
        let response = try {
            dispatch(message, SERVER_TOOLS)
        } catch (error: Exception) {
            logFailure("dispatch failed", error)
            Some(buildError(None, INTERNAL_ERROR, "Internal error"))
        }
        if (let Some(payload) <- response) {
            writer.writeln(toCompactJson(payload))
            writer.flush()
        }
    }
}
