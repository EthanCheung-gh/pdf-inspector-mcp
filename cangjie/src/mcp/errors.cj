package pdf_inspector_mcp.mcp

/**
 * A failure whose message is safe and useful to show the MCP client verbatim.
 *
 * Raise it for anticipated, user-facing problems: a path that is not a readable
 * PDF, a page number outside the document, an unsupported `format`/`scope`
 * value, a missing or wrong password, and so on. The stdio server turns it into
 * a `tools/call` result with `isError: true` and `message` as the text, so the
 * model can react to it.
 *
 * Anything else that escapes a tool is treated as an internal failure: it is
 * logged to stderr and the client only receives a generic message.
 */
public class PdfToolError <: Exception {
    public init(message: String) {
        super(message)
    }
}
