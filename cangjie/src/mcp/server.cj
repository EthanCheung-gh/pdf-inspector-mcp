package pdf_inspector_mcp.mcp

import magic.core.tool.{Tool, ToolException, ToolResponse}

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
 * Wire format: one JSON-RPC 2.0 message per line on stdin, one response per
 * line on stdout (always flushed). Diagnostics go to stderr only.
 */

private let JSONRPC_VERSION = "2.0"
private let DEFAULT_PROTOCOL_VERSION = "2024-11-05"
private let SERVER_NAME = "pdf-inspector"
private let SERVER_VERSION = "0.1.0-cangjie"

// JSON-RPC 2.0 error codes.
private let PARSE_ERROR = -32700
private let INVALID_REQUEST = -32600
private let METHOD_NOT_FOUND = -32601
private let INVALID_PARAMS = -32602
private let INTERNAL_ERROR = -32603

/**
 * The registered tools. `tool.toJsonValue()` is used for `tools/list` on
 * purpose: it honours `ToolParameter.required`, which the `@tool` macro derives
 * from `Option<T>` parameters, so optional arguments are not advertised as
 * required.
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
    var protocolVersion = DEFAULT_PROTOCOL_VERSION
    if (let Some(paramsObject) <- params) {
        if (let Some(version) <- readString(paramsObject, "protocolVersion")) {
            if (!version.isEmpty()) {
                protocolVersion = version
            }
        }
    }

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

private func buildToolsListResult(tools: Array<Tool>): JsonValue {
    let items = ArrayList<JsonValue>()
    for (tool in tools) {
        items.add(tool.toJsonValue())
    }
    let result = JsonObject()
    result.put("tools", JsonArray(items.toArray()))
    return result
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
