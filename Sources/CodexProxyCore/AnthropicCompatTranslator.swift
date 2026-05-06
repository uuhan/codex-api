import Foundation

enum AnthropicCompatTranslator {
    static func messagesToCodex(_ request: JSONObject, model: String, stream: Bool) -> JSONObject {
        let toolNameMap = shortNameMap(from: JSONHelper.array(request["tools"]))
        var output: JSONObject = [
            "instructions": "",
            "stream": stream,
            "model": model,
            "parallel_tool_calls": parallelToolCalls(from: request),
            "reasoning": [
                "effort": reasoningEffort(from: JSONHelper.object(request["thinking"]), outputConfig: JSONHelper.object(request["output_config"])),
                "summary": "auto"
            ],
            "include": ["reasoning.encrypted_content"],
            "input": [],
            "store": false
        ]

        var input: [Any] = []
        if let system = developerMessage(from: request["system"]) {
            input.append(system)
        }
        if let messages = JSONHelper.array(request["messages"]) {
            for item in messages {
                guard let message = JSONHelper.object(item) else {
                    continue
                }
                input.append(contentsOf: codexInputItems(fromAnthropicMessage: message, toolNameMap: toolNameMap))
            }
        }
        output["input"] = input

        if let tools = JSONHelper.array(request["tools"]) {
            let converted = tools.compactMap { codexTool(from: $0, toolNameMap: toolNameMap) }
            if !converted.isEmpty {
                output["tools"] = converted
            }
        }

        if let toolChoice = request["tool_choice"] {
            output["tool_choice"] = codexToolChoice(from: toolChoice, toolNameMap: toolNameMap, tools: JSONHelper.array(request["tools"]))
        }

        return output
    }

    static func messageObject(fromCompletedEvent event: JSONObject, originalRequest: JSONObject, requestedModel: String? = nil) -> JSONObject? {
        guard let response = JSONHelper.object(event["response"]) else {
            return nil
        }
        let reverseToolNames = reverseShortNameMap(from: JSONHelper.array(originalRequest["tools"]))
        let output = JSONHelper.array(response["output"]) ?? []
        var content: [Any] = []
        var hasToolCall = false

        for item in output {
            guard let object = JSONHelper.object(item),
                  let type = JSONHelper.string(object["type"]) else {
                continue
            }
            switch type {
            case "reasoning":
                let thinking = reasoningText(from: object)
                let signature = JSONHelper.string(object["encrypted_content"]) ?? ""
                if !thinking.isEmpty || !signature.isEmpty {
                    var block: JSONObject = ["type": "thinking", "thinking": thinking]
                    if !signature.isEmpty {
                        block["signature"] = signature
                    }
                    content.append(block)
                }
            case "message":
                for text in outputTexts(from: object) where !text.isEmpty {
                    content.append(["type": "text", "text": text])
                }
            case "function_call":
                hasToolCall = true
                var name = JSONHelper.string(object["name"]) ?? ""
                if let restored = reverseToolNames[name] {
                    name = restored
                }
                content.append([
                    "type": "tool_use",
                    "id": sanitizeToolID(JSONHelper.string(object["call_id"]) ?? JSONHelper.string(object["id"]) ?? "toolu_\(UUID().uuidString)"),
                    "name": name,
                    "input": argumentsObject(from: JSONHelper.string(object["arguments"]))
                ])
            default:
                continue
            }
        }

        var result: JSONObject = [
            "id": JSONHelper.string(response["id"]) ?? "msg_\(UUID().uuidString)",
            "type": "message",
            "role": "assistant",
            "model": JSONHelper.string(response["model"]) ?? requestedModel ?? JSONHelper.string(originalRequest["model"]) ?? "",
            "content": content,
            "stop_reason": stopReason(from: response, hasToolCall: hasToolCall),
            "stop_sequence": stopSequence(from: response),
            "usage": usage(from: JSONHelper.object(response["usage"]))
        ]
        if let requestedModel = normalizedModel(requestedModel ?? JSONHelper.string(originalRequest["model"])) {
            result["requested_model"] = requestedModel
        }
        return result
    }

    static func tokenCountObject(for request: JSONObject) -> JSONObject {
        let raw = (try? JSONHelper.data(request)) ?? Data()
        return ["input_tokens": max(1, raw.count / 4)]
    }

    static func restoredToolName(_ name: String, originalRequest: JSONObject) -> String {
        reverseShortNameMap(from: JSONHelper.array(originalRequest["tools"]))[name] ?? name
    }

    private static func developerMessage(from system: Any?) -> JSONObject? {
        var content: [Any] = []
        func appendText(_ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("x-anthropic-billing-header: ") else {
                return
            }
            content.append(["type": "input_text", "text": trimmed])
        }

        if let text = JSONHelper.string(system) {
            appendText(text)
        } else if let array = JSONHelper.array(system) {
            for item in array {
                guard let object = JSONHelper.object(item),
                      JSONHelper.string(object["type"]) == "text" else {
                    continue
                }
                appendText(JSONHelper.string(object["text"]) ?? "")
            }
        }

        guard !content.isEmpty else {
            return nil
        }
        return ["type": "message", "role": "developer", "content": content]
    }

    private static func codexInputItems(fromAnthropicMessage message: JSONObject, toolNameMap: [String: String]) -> [Any] {
        let role = JSONHelper.string(message["role"]) ?? "user"
        var items: [Any] = []
        var content: [Any] = []

        func flushMessage() {
            guard !content.isEmpty else {
                return
            }
            items.append([
                "type": "message",
                "role": role,
                "content": content
            ])
            content.removeAll()
        }

        func appendText(_ text: String) {
            content.append([
                "type": role == "assistant" ? "output_text" : "input_text",
                "text": text
            ])
        }

        if let text = JSONHelper.string(message["content"]) {
            appendText(text)
            flushMessage()
            return items
        }

        guard let parts = JSONHelper.array(message["content"]) else {
            return items
        }

        for part in parts {
            guard let object = JSONHelper.object(part),
                  let type = JSONHelper.string(object["type"]) else {
                continue
            }
            switch type {
            case "text":
                appendText(JSONHelper.string(object["text"]) ?? "")
            case "image":
                if role == "user", let imageURL = dataURL(fromAnthropicImage: object) {
                    content.append(["type": "input_image", "image_url": imageURL])
                }
            case "thinking":
                if role == "assistant", let signature = JSONHelper.string(object["signature"]), !signature.isEmpty {
                    flushMessage()
                    items.append([
                        "type": "reasoning",
                        "summary": [],
                        "content": NSNull(),
                        "encrypted_content": signature
                    ])
                }
            case "tool_use":
                flushMessage()
                let originalName = JSONHelper.string(object["name"]) ?? ""
                items.append([
                    "type": "function_call",
                    "call_id": JSONHelper.string(object["id"]) ?? "",
                    "name": toolNameMap[originalName] ?? shortenNameIfNeeded(originalName),
                    "arguments": jsonString(object["input"] ?? [:])
                ])
            case "tool_result":
                flushMessage()
                var output: JSONObject = [
                    "type": "function_call_output",
                    "call_id": JSONHelper.string(object["tool_use_id"]) ?? ""
                ]
                output["output"] = toolResultOutput(from: object["content"])
                items.append(output)
            default:
                continue
            }
        }

        flushMessage()
        return items
    }

    private static func dataURL(fromAnthropicImage object: JSONObject) -> String? {
        guard let source = JSONHelper.object(object["source"]) else {
            return nil
        }
        let data = JSONHelper.string(source["data"]) ?? JSONHelper.string(source["base64"]) ?? ""
        guard !data.isEmpty else {
            return nil
        }
        let mediaType = JSONHelper.string(source["media_type"]) ?? JSONHelper.string(source["mime_type"]) ?? "application/octet-stream"
        return "data:\(mediaType);base64,\(data)"
    }

    private static func toolResultOutput(from content: Any?) -> Any {
        if let text = JSONHelper.string(content) {
            return text
        }
        guard let parts = JSONHelper.array(content) else {
            return content.map { JSONHelper.compactString($0) } ?? ""
        }

        var output: [Any] = []
        for part in parts {
            guard let object = JSONHelper.object(part),
                  let type = JSONHelper.string(object["type"]) else {
                output.append(["type": "input_text", "text": JSONHelper.compactString(part)])
                continue
            }
            switch type {
            case "text":
                output.append(["type": "input_text", "text": JSONHelper.string(object["text"]) ?? ""])
            case "image":
                if let imageURL = dataURL(fromAnthropicImage: object) {
                    output.append(["type": "input_image", "image_url": imageURL])
                }
            default:
                output.append(["type": "input_text", "text": JSONHelper.compactString(part)])
            }
        }
        return output.isEmpty ? "" : output
    }

    private static func codexTool(from item: Any, toolNameMap: [String: String]) -> Any? {
        guard let object = JSONHelper.object(item) else {
            return nil
        }

        if isClaudeWebSearchToolType(JSONHelper.string(object["type"]) ?? "") {
            var out: JSONObject = ["type": "web_search"]
            if let allowedDomains = JSONHelper.array(object["allowed_domains"]) {
                out["filters"] = ["allowed_domains": allowedDomains]
            }
            if let userLocation = JSONHelper.object(object["user_location"]) {
                out["user_location"] = userLocation
            }
            return out
        }

        let originalName = JSONHelper.string(object["name"]) ?? ""
        guard !originalName.isEmpty else {
            return nil
        }
        var out: JSONObject = [
            "type": "function",
            "name": toolNameMap[originalName] ?? shortenNameIfNeeded(originalName),
            "parameters": normalizeToolParameters(object["input_schema"]),
            "strict": false
        ]
        if let description = object["description"] {
            out["description"] = description
        }
        return out
    }

    private static func codexToolChoice(from value: Any, toolNameMap: [String: String], tools: JSONArray?) -> Any {
        var webSearchNames = Set<String>()
        for item in tools ?? [] {
            guard let object = JSONHelper.object(item),
                  isClaudeWebSearchToolType(JSONHelper.string(object["type"]) ?? ""),
                  let name = JSONHelper.string(object["name"]) else {
                continue
            }
            webSearchNames.insert(name)
        }

        if let string = JSONHelper.string(value) {
            switch string {
            case "any":
                return "required"
            default:
                return string
            }
        }

        guard let object = JSONHelper.object(value) else {
            return value
        }
        let type = JSONHelper.string(object["type"]) ?? "auto"
        switch type {
        case "auto":
            return "auto"
        case "any":
            return "required"
        case "none":
            return "none"
        case "tool":
            let originalName = JSONHelper.string(object["name"]) ?? ""
            if webSearchNames.contains(originalName) {
                return ["type": "web_search"]
            }
            let name = toolNameMap[originalName] ?? shortenNameIfNeeded(originalName)
            return name.isEmpty ? "auto" : ["type": "function", "name": name]
        default:
            return "auto"
        }
    }

    private static func parallelToolCalls(from request: JSONObject) -> Bool {
        guard let choice = JSONHelper.object(request["tool_choice"]),
              choice["disable_parallel_tool_use"] != nil else {
            return true
        }
        return !JSONHelper.bool(choice["disable_parallel_tool_use"])
    }

    private static func reasoningEffort(from thinking: JSONObject?, outputConfig: JSONObject?) -> String {
        guard let thinking,
              let type = JSONHelper.string(thinking["type"]) else {
            return "medium"
        }
        switch type {
        case "disabled":
            return "low"
        case "adaptive", "auto":
            return JSONHelper.string(outputConfig?["effort"])?.lowercased() ?? "xhigh"
        case "enabled":
            let budget = intValue(thinking["budget_tokens"]) ?? 8192
            switch budget {
            case ...1024:
                return "low"
            case ...8192:
                return "medium"
            case ...24576:
                return "high"
            default:
                return "xhigh"
            }
        default:
            return "medium"
        }
    }

    fileprivate static func usage(from usage: JSONObject?) -> JSONObject {
        guard let usage else {
            return ["input_tokens": 0, "output_tokens": 0]
        }
        let cached = intValue(JSONHelper.object(usage["input_tokens_details"])?["cached_tokens"]) ?? 0
        let input = max(0, (intValue(usage["input_tokens"]) ?? 0) - cached)
        var out: JSONObject = [
            "input_tokens": input,
            "output_tokens": intValue(usage["output_tokens"]) ?? 0
        ]
        if cached > 0 {
            out["cache_read_input_tokens"] = cached
        }
        return out
    }

    private static func reasoningText(from object: JSONObject) -> String {
        var text = ""
        if let summary = JSONHelper.array(object["summary"]) {
            for part in summary {
                if let partObject = JSONHelper.object(part) {
                    text += JSONHelper.string(partObject["text"]) ?? JSONHelper.compactString(partObject)
                } else {
                    text += JSONHelper.string(part) ?? "\(part)"
                }
            }
        } else if let content = JSONHelper.array(object["content"]) {
            for part in content {
                if let partObject = JSONHelper.object(part) {
                    text += JSONHelper.string(partObject["text"]) ?? JSONHelper.compactString(partObject)
                }
            }
        } else if let content = JSONHelper.string(object["content"]) {
            text += content
        }
        return text
    }

    private static func outputTexts(from object: JSONObject) -> [String] {
        guard let content = JSONHelper.array(object["content"]) else {
            return JSONHelper.string(object["content"]).map { [$0] } ?? []
        }
        return content.compactMap { part in
            guard let object = JSONHelper.object(part),
                  JSONHelper.string(object["type"]) == "output_text" else {
                return nil
            }
            return JSONHelper.string(object["text"])
        }
    }

    fileprivate static func stopReason(from response: JSONObject, hasToolCall: Bool) -> String {
        if hasToolCall {
            return "tool_use"
        }
        let reason = JSONHelper.string(response["stop_reason"]) ?? JSONHelper.string(JSONHelper.object(response["incomplete_details"])?["reason"]) ?? ""
        switch reason {
        case "", "stop", "completed":
            return "end_turn"
        case "max_tokens", "max_output_tokens":
            return "max_tokens"
        case "tool_use", "tool_calls", "function_call":
            return "tool_use"
        case "content_filter":
            return "refusal"
        default:
            return reason
        }
    }

    private static func stopSequence(from response: JSONObject) -> Any {
        guard let value = response["stop_sequence"],
              !(value is NSNull) else {
            return NSNull()
        }
        return value
    }

    private static func argumentsObject(from value: String?) -> JSONObject {
        guard let value,
              let data = value.data(using: .utf8),
              let object = try? JSONHelper.object(from: data) else {
            return [:]
        }
        return object
    }

    private static func normalizeToolParameters(_ value: Any?) -> JSONObject {
        guard var schema = JSONHelper.object(value) else {
            return ["type": "object", "properties": [:]]
        }
        if JSONHelper.string(schema["type"]) == nil {
            schema["type"] = "object"
        }
        if JSONHelper.string(schema["type"]) == "object", schema["properties"] == nil {
            schema["properties"] = [:]
        }
        return schema
    }

    private static func isClaudeWebSearchToolType(_ type: String) -> Bool {
        type == "web_search_20250305" || type == "web_search_20260209"
    }

    private static func shortNameMap(from tools: JSONArray?) -> [String: String] {
        let names = (tools ?? []).compactMap { item -> String? in
            guard let object = JSONHelper.object(item),
                  !isClaudeWebSearchToolType(JSONHelper.string(object["type"]) ?? "") else {
                return nil
            }
            return JSONHelper.string(object["name"])
        }
        return buildShortNameMap(names)
    }

    private static func reverseShortNameMap(from tools: JSONArray?) -> [String: String] {
        var reverse: [String: String] = [:]
        for (original, short) in shortNameMap(from: tools) {
            reverse[short] = original
        }
        return reverse
    }

    private static func shortenNameIfNeeded(_ name: String) -> String {
        let limit = 64
        guard name.count > limit else {
            return name
        }
        if name.hasPrefix("mcp__"), let range = name.range(of: "__", options: .backwards) {
            let candidate = "mcp__" + name[range.upperBound...]
            return String(candidate.prefix(limit))
        }
        return String(name.prefix(limit))
    }

    private static func buildShortNameMap(_ names: [String]) -> [String: String] {
        let limit = 64
        var used = Set<String>()
        var result: [String: String] = [:]

        func baseCandidate(_ name: String) -> String {
            guard name.count > limit else {
                return name
            }
            if name.hasPrefix("mcp__"), let range = name.range(of: "__", options: .backwards) {
                return String(("mcp__" + name[range.upperBound...]).prefix(limit))
            }
            return String(name.prefix(limit))
        }

        for name in names {
            let base = baseCandidate(name)
            var candidate = base
            var index = 1
            while used.contains(candidate) {
                let suffix = "_\(index)"
                candidate = String(base.prefix(max(0, limit - suffix.count))) + suffix
                index += 1
            }
            used.insert(candidate)
            result[name] = candidate
        }
        return result
    }

    private static func jsonString(_ value: Any) -> String {
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        if let string = JSONHelper.string(value) {
            return string
        }
        return JSONHelper.compactString(value)
    }

    private static func normalizedModel(_ model: String?) -> String? {
        guard let model else {
            return nil
        }
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value)
        default:
            return nil
        }
    }

    static func sanitizeToolID(_ id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let filtered = String(id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        let trimmed = filtered.trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
        if trimmed.isEmpty {
            return "toolu_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        }
        return String(trimmed.prefix(128))
    }
}

struct AnthropicStreamTranslator {
    private var responseID = ""
    private var model = ""
    private var blockIndex = 0
    private var hasToolCall = false
    private var hasTextDelta = false
    private var textBlockOpen = false
    private var thinkingBlockOpen = false
    private var thinkingStopPending = false
    private var thinkingSignature = ""
    private var hasReceivedArgumentsDelta = false
    private let requestedModel: String
    private let originalRequest: JSONObject

    init(requestedModel: String, originalRequest: JSONObject) {
        self.requestedModel = requestedModel
        self.originalRequest = originalRequest
        self.model = requestedModel
    }

    mutating func translate(payload: JSONObject) throws -> [SSEFrame] {
        guard let type = JSONHelper.string(payload["type"]) else {
            return []
        }

        var frames: [SSEFrame] = []
        if thinkingBlockOpen && thinkingStopPending && shouldFinalizeThinking(before: payload) {
            frames.append(contentsOf: try finalizeThinkingBlock())
        }

        switch type {
        case "response.created":
            guard let response = JSONHelper.object(payload["response"]) else {
                return []
            }
            responseID = JSONHelper.string(response["id"]) ?? responseID
            model = JSONHelper.string(response["model"]) ?? model
            let message: JSONObject = [
                "id": responseID,
                "type": "message",
                "role": "assistant",
                "model": model,
                "content": [],
                "stop_reason": NSNull(),
                "stop_sequence": NSNull(),
                "usage": ["input_tokens": 0, "output_tokens": 0]
            ]
            frames.append(try frame(event: "message_start", object: ["type": "message_start", "message": message]))
        case "response.reasoning_summary_part.added":
            frames.append(contentsOf: try startThinkingBlock())
        case "response.reasoning_summary_text.delta":
            frames.append(try contentDelta(type: "thinking_delta", key: "thinking", value: JSONHelper.string(payload["delta"]) ?? ""))
        case "response.reasoning_summary_part.done":
            thinkingStopPending = true
        case "response.content_part.added":
            frames.append(contentsOf: try startTextBlock())
        case "response.output_text.delta":
            if !textBlockOpen {
                frames.append(contentsOf: try startTextBlock())
            }
            hasTextDelta = true
            frames.append(try contentDelta(type: "text_delta", key: "text", value: JSONHelper.string(payload["delta"]) ?? ""))
        case "response.content_part.done":
            frames.append(contentsOf: try stopTextBlock())
        case "response.output_item.added":
            guard let item = JSONHelper.object(payload["item"]) else {
                return frames
            }
            if JSONHelper.string(item["type"]) == "function_call" {
                frames.append(contentsOf: try startToolUseBlock(item: item))
            } else if JSONHelper.string(item["type"]) == "reasoning" {
                thinkingSignature = JSONHelper.string(item["encrypted_content"]) ?? thinkingSignature
            }
        case "response.function_call_arguments.delta":
            hasReceivedArgumentsDelta = true
            frames.append(try contentDelta(type: "input_json_delta", key: "partial_json", value: JSONHelper.string(payload["delta"]) ?? ""))
        case "response.function_call_arguments.done":
            if !hasReceivedArgumentsDelta, let arguments = JSONHelper.string(payload["arguments"]), !arguments.isEmpty {
                frames.append(try contentDelta(type: "input_json_delta", key: "partial_json", value: arguments))
            }
        case "response.output_item.done":
            guard let item = JSONHelper.object(payload["item"]) else {
                return frames
            }
            if JSONHelper.string(item["type"]) == "function_call" {
                frames.append(try stopBlock())
            } else if JSONHelper.string(item["type"]) == "message", !hasTextDelta {
                frames.append(contentsOf: try messageFallbackTextFrames(from: item))
            } else if JSONHelper.string(item["type"]) == "reasoning" {
                thinkingSignature = JSONHelper.string(item["encrypted_content"]) ?? thinkingSignature
                frames.append(contentsOf: try finalizeSignatureOnlyThinkingBlock())
            }
        case "response.completed", "response.incomplete":
            if textBlockOpen {
                frames.append(contentsOf: try stopTextBlock())
            }
            frames.append(contentsOf: try finalizeThinkingBlock())
            let response = JSONHelper.object(payload["response"]) ?? [:]
            let object: JSONObject = [
                "type": "message_delta",
                "delta": [
                    "stop_reason": AnthropicCompatTranslator.stopReason(from: response, hasToolCall: hasToolCall),
                    "stop_sequence": response["stop_sequence"] ?? NSNull()
                ],
                "usage": AnthropicCompatTranslator.usage(from: JSONHelper.object(response["usage"]))
            ]
            frames.append(try frame(event: "message_delta", object: object))
            frames.append(try frame(event: "message_stop", object: ["type": "message_stop"]))
        default:
            break
        }

        return frames
    }

    private func shouldFinalizeThinking(before payload: JSONObject) -> Bool {
        switch JSONHelper.string(payload["type"]) {
        case "response.content_part.added", "response.completed", "response.incomplete":
            return true
        case "response.output_item.added":
            return JSONHelper.string(JSONHelper.object(payload["item"])?["type"]) == "function_call"
        default:
            return false
        }
    }

    private mutating func startTextBlock() throws -> [SSEFrame] {
        guard !textBlockOpen else {
            return []
        }
        textBlockOpen = true
        let object: JSONObject = [
            "type": "content_block_start",
            "index": blockIndex,
            "content_block": ["type": "text", "text": ""]
        ]
        return [try frame(event: "content_block_start", object: object)]
    }

    private mutating func stopTextBlock() throws -> [SSEFrame] {
        guard textBlockOpen else {
            return []
        }
        let object: JSONObject = ["type": "content_block_stop", "index": blockIndex]
        textBlockOpen = false
        blockIndex += 1
        return [try frame(event: "content_block_stop", object: object)]
    }

    private mutating func startThinkingBlock() throws -> [SSEFrame] {
        guard !thinkingBlockOpen else {
            return []
        }
        thinkingBlockOpen = true
        thinkingStopPending = false
        let object: JSONObject = [
            "type": "content_block_start",
            "index": blockIndex,
            "content_block": ["type": "thinking", "thinking": ""]
        ]
        return [try frame(event: "content_block_start", object: object)]
    }

    private mutating func finalizeSignatureOnlyThinkingBlock() throws -> [SSEFrame] {
        guard !thinkingSignature.isEmpty else {
            return []
        }
        var frames = try startThinkingBlock()
        frames.append(contentsOf: try finalizeThinkingBlock())
        return frames
    }

    private mutating func finalizeThinkingBlock() throws -> [SSEFrame] {
        guard thinkingBlockOpen else {
            return []
        }
        var frames: [SSEFrame] = []
        if !thinkingSignature.isEmpty {
            let object: JSONObject = [
                "type": "content_block_delta",
                "index": blockIndex,
                "delta": ["type": "signature_delta", "signature": thinkingSignature]
            ]
            frames.append(try frame(event: "content_block_delta", object: object))
            thinkingSignature = ""
        }
        frames.append(try stopBlock())
        thinkingBlockOpen = false
        thinkingStopPending = false
        return frames
    }

    private mutating func startToolUseBlock(item: JSONObject) throws -> [SSEFrame] {
        hasToolCall = true
        hasReceivedArgumentsDelta = false
        var name = JSONHelper.string(item["name"]) ?? ""
        name = AnthropicCompatTranslator.restoredToolName(name, originalRequest: originalRequest)
        let object: JSONObject = [
            "type": "content_block_start",
            "index": blockIndex,
            "content_block": [
                "type": "tool_use",
                "id": AnthropicCompatTranslator.sanitizeToolID(JSONHelper.string(item["call_id"]) ?? JSONHelper.string(item["id"]) ?? "toolu_\(UUID().uuidString)"),
                "name": name,
                "input": [:]
            ]
        ]
        return [
            try frame(event: "content_block_start", object: object),
            try contentDelta(type: "input_json_delta", key: "partial_json", value: "")
        ]
    }

    private mutating func stopBlock() throws -> SSEFrame {
        let object: JSONObject = ["type": "content_block_stop", "index": blockIndex]
        blockIndex += 1
        return try frame(event: "content_block_stop", object: object)
    }

    private mutating func messageFallbackTextFrames(from item: JSONObject) throws -> [SSEFrame] {
        let text = outputTexts(from: item).joined()
        guard !text.isEmpty else {
            return []
        }
        var frames = try startTextBlock()
        frames.append(try contentDelta(type: "text_delta", key: "text", value: text))
        frames.append(contentsOf: try stopTextBlock())
        hasTextDelta = true
        return frames
    }

    private func outputTexts(from object: JSONObject) -> [String] {
        guard let content = JSONHelper.array(object["content"]) else {
            return JSONHelper.string(object["content"]).map { [$0] } ?? []
        }
        return content.compactMap { part in
            guard let object = JSONHelper.object(part),
                  JSONHelper.string(object["type"]) == "output_text" else {
                return nil
            }
            return JSONHelper.string(object["text"])
        }
    }

    private func contentDelta(type: String, key: String, value: String) throws -> SSEFrame {
        try frame(event: "content_block_delta", object: [
            "type": "content_block_delta",
            "index": blockIndex,
            "delta": ["type": type, key: value]
        ])
    }

    private func frame(event: String, object: JSONObject) throws -> SSEFrame {
        SSEFrame(event: event, data: try JSONHelper.data(object))
    }
}
