import Foundation

/// One row of a `session.transcript` page; `kind` names which optional fields apply (control-api.md).
public struct ControlTranscriptItem: Codable, Sendable, Equatable {
    public var kind: String
    public var uuid: String
    public var at: Int
    public var time: String?
    public var text: String?
    public var promptSource: String?
    public var origin: String?
    public var clipped: Bool?
    public var mediaType: String?
    public var bytes: Int?
    public var data: String?
    public var name: String?
    public var args: String?
    public var message: String?
    public var durationMs: Int?
    public var id: String?
    public var arg: String?
    public var mark: String?
    public var running: Bool?
    public var output: String?
    public var patch: [ControlTranscriptHunk]?
    public var file: String?
    public var isError: Bool?
    public var rejected: Bool?
    public var exitCode: Int?
    public var readOnly: Bool?
    public var agentType: String?
    public var agentName: String?
    public var agentColor: String?
    public var trigger: String?
    public var level: String?

    public init(kind: String, uuid: String, at: Int, time: String? = nil) {
        self.kind = kind
        self.uuid = uuid
        self.at = at
        self.time = time
    }
}

public struct ControlTranscriptHunk: Codable, Sendable, Equatable {
    public var oldStart: Int
    public var oldLines: Int
    public var newStart: Int
    public var newLines: Int
    public var lines: [String]

    public init(oldStart: Int, oldLines: Int, newStart: Int, newLines: Int, lines: [String]) {
        self.oldStart = oldStart
        self.oldLines = oldLines
        self.newStart = newStart
        self.newLines = newLines
        self.lines = lines
    }
}

/// An open prompt-capable tool call; `source` is `main` or the bare subagent id.
public struct ControlTranscriptPending: Codable, Sendable, Equatable {
    public var id: String
    public var uuid: String
    public var source: String
    public var agentType: String?
    public var agentName: String?
    public var name: String
    public var input: JSONValue?
    public var clipped: Bool?

    public init(id: String, uuid: String, source: String, agentType: String? = nil, agentName: String? = nil,
                name: String, input: JSONValue? = nil, clipped: Bool? = nil) {
        self.id = id
        self.uuid = uuid
        self.source = source
        self.agentType = agentType
        self.agentName = agentName
        self.name = name
        self.input = input
        self.clipped = clipped
    }
}

public struct ControlTranscriptPR: Codable, Sendable, Equatable {
    public var prNumber: Int?
    public var prRepository: String?
    public var prUrl: String?

    public init(prNumber: Int? = nil, prRepository: String? = nil, prUrl: String? = nil) {
        self.prNumber = prNumber
        self.prRepository = prRepository
        self.prUrl = prUrl
    }
}

public struct ControlTranscriptTodo: Codable, Sendable, Equatable {
    public var content: String
    public var status: String
    public var activeForm: String?

    public init(content: String, status: String, activeForm: String? = nil) {
        self.content = content
        self.status = status
        self.activeForm = activeForm
    }
}

/// Session-wide fields folded from the whole file, the last record of each type winning.
public struct ControlTranscriptMeta: Codable, Sendable, Equatable {
    public var title: String?
    public var lastPrompt: String?
    public var permissionMode: String?
    public var pr: ControlTranscriptPR?
    public var agentName: String?
    public var model: String?
    public var effort: String?
    public var todos: [ControlTranscriptTodo]?
    public var queued: [String]?
    public var continuedIn: String?
    public var skillsAt: Int?
    public var agents: [ControlTranscriptAgent]?

    public init() {}
}

/// One subagent; `id` is its Agent call's tool_use id and `state` is `running`, `done`, `failed` or `stopped`.
public struct ControlTranscriptAgent: Codable, Sendable, Equatable {
    public var id: String
    public var agentType: String?
    public var name: String?
    public var color: String?
    public var description: String?
    public var startedAt: String?
    public var state: String

    public init(id: String, state: String) {
        self.id = id
        self.state = state
    }
}

public struct ControlTranscriptCommand: Codable, Sendable, Equatable {
    public var name: String
    public var description: String
    public var source: String
    public var panel: Bool?

    public init(name: String, description: String, source: String, panel: Bool? = nil) {
        self.name = name
        self.description = description
        self.source = source
        self.panel = panel
    }
}

/// Any JSON value, so a tool input travels as written.
public indirect enum JSONValue: Codable, Sendable, Equatable {
    case string(String), number(Double), bool(Bool), null, array([JSONValue]), object([String: JSONValue])

    /// From `JSONSerialization` output. It round-trips through `JSONDecoder` because an `NSNumber` cannot tell
    /// `true` from `1` portably across Darwin and Linux.
    public init?(any: Any) {
        guard JSONSerialization.isValidJSONObject([any]),
              let data = try? JSONSerialization.data(withJSONObject: [any]),
              let values = try? JSONDecoder().decode([JSONValue].self, from: data),
              let value = values.first
        else { return nil }
        self = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// The transcript a host found for the addressed pane; the host names its Claude directory, so tests point it at a temp dir.
public struct ControlTranscriptSource: Sendable, Equatable {
    public var claudeSessionID: String
    public var pane: StatusPane
    public var claudeDirectory: String

    public init(claudeSessionID: String, pane: StatusPane, claudeDirectory: String) {
        self.claudeSessionID = claudeSessionID
        self.pane = pane
        self.claudeDirectory = claudeDirectory
    }
}

public enum ControlTranscriptLookup: Sendable, Equatable {
    case source(ControlTranscriptSource)
    case refused(ControlResponse)

    /// What a host predating `session.transcript` answers; the phone reads `too old` as a host without Chat.
    public static let tooOld = ControlTranscriptLookup.refused(
        ControlResponse(ok: false, error: "the Elis on this host is too old for session.transcript"))
}

public struct ControlTranscriptRefusal: Error, Equatable {
    public let message: String

    public init(message: String) { self.message = message }

    public static let noAdapter = ControlTranscriptRefusal(message: "no adapter")
}

/// TranscriptForward is a `session.transcript` read as the remote host's own `elisctl` arguments.
public enum TranscriptForward {
    /// words join each free value to its flag, so a value starting with `-` is never read as an option.
    public static func words(session: String, paneID: String?, pane: StatusPane?, arguments: ClaudeTranscriptArguments) -> [String] {
        ["session", "transcript", "--target", session]
            + (paneID.map { ["--pane-id=" + $0] } ?? pane.map { ["--pane", $0.rawValue] } ?? [])
            + (arguments.after.map { ["--after=\($0)"] } ?? []) + (arguments.before.map { ["--before=\($0)"] } ?? [])
            + (arguments.held.map { ["--transcript=" + $0] } ?? []) + ["--max-bytes=\(arguments.maxBytes)"]
    }
}
