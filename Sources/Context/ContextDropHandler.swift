import Foundation
import AppKit
import UniformTypeIdentifiers

/// Handles drag & drop of code/text into the context panel.
/// Creates a temporary file with the dropped content, then spawns
/// an ephemeral Claude Code terminal to analyze and transform it
/// into a context entry.
@MainActor
final class ContextDropHandler {

    /// Supported drop types for the context panel.
    static let supportedTypes: [UTType] = [
        .plainText,
        .utf8PlainText,
        .fileURL
    ]

    /// Process dropped content and spawn a Claude terminal for transformation.
    /// - Parameters:
    ///   - providers: The NSItemProvider array from the drop event
    ///   - config: The drag & drop configuration
    ///   - onSpawnTerminal: Callback to spawn the ephemeral terminal with a command
    static func handleDrop(
        providers: [NSItemProvider],
        config: DragDropConfig,
        onSpawnTerminal: @escaping (String) -> Void
    ) {
        for provider in providers {
            // Handle plain text
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, error in
                    guard let text = item as? String, !text.isEmpty, error == nil else { return }
                    DispatchQueue.main.async {
                        Self.processText(text, config: config, onSpawnTerminal: onSpawnTerminal)
                    }
                }
                return
            }

            // Handle file URLs
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    guard error == nil else { return }
                    var fileURL: URL?
                    if let data = item as? Data {
                        fileURL = URL(dataRepresentation: data, relativeTo: nil)
                    } else if let url = item as? URL {
                        fileURL = url
                    }
                    guard let url = fileURL else { return }
                    if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
                        let filename = url.lastPathComponent
                        DispatchQueue.main.async {
                            Self.processText("# File: \(filename)\n\n\(text)", config: config, onSpawnTerminal: onSpawnTerminal)
                        }
                    }
                }
                return
            }
        }
    }

    /// Write dropped text to temp file and build Claude command.
    private static func processText(
        _ text: String,
        config: DragDropConfig,
        onSpawnTerminal: @escaping (String) -> Void
    ) {
        // Write to temp file
        let uuid = UUID().uuidString.prefix(8)
        let tmpPath = "/tmp/cmux-context-drop-\(uuid).txt"
        do {
            try text.write(toFile: tmpPath, atomically: true, encoding: .utf8)
        } catch {
            NSLog("ContextDropHandler: failed to write temp file: \(error)")
            return
        }

        // Resolve transform prompt path
        let promptPath = config.transformPromptPath ?? defaultTransformPromptPath()

        // Build Claude command
        let command = buildClaudeCommand(
            droppedFilePath: tmpPath,
            promptPath: promptPath,
            autoClose: config.autoCloseTerminal
        )

        onSpawnTerminal(command)
    }

    /// Build the Claude Code command to process dropped content.
    private static func buildClaudeCommand(
        droppedFilePath: String,
        promptPath: String,
        autoClose: Bool
    ) -> String {
        // Read prompt if available
        var systemPromptArg = ""
        if FileManager.default.fileExists(atPath: promptPath),
           let prompt = try? String(contentsOfFile: promptPath, encoding: .utf8) {
            // Escape for shell
            let escaped = prompt.replacingOccurrences(of: "'", with: "'\\''")
            systemPromptArg = " --system-prompt '\(escaped)'"
        }

        let printArg = """
        Analyze the content in \(droppedFilePath) and save it to the team context. \
        Use cmux context CLI commands (cmux context set, cmux context doc create, cmux context entity create). \
        Show me what you'll create before executing. After saving, confirm what was added.
        """
        let escapedPrint = printArg.replacingOccurrences(of: "'", with: "'\\''")

        var cmd = "claude\(systemPromptArg) --print '\(escapedPrint)'"

        // Clean up temp file after Claude exits
        cmd += " ; rm -f '\(droppedFilePath)'"

        return cmd
    }

    /// Default path for the transform prompt.
    private static func defaultTransformPromptPath() -> String {
        // Check bundle first
        if let bundlePath = Bundle.main.path(forResource: "context-transform-prompt", ofType: "md") {
            return bundlePath
        }
        // Fall back to user config
        return NSHomeDirectory() + "/.config/cmux/context-transform-prompt.md"
    }
}
