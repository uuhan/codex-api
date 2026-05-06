import Foundation

struct SSEFrame {
    var event: String?
    var data: Data

    var dataString: String {
        String(data: data, encoding: .utf8) ?? ""
    }

    func serialized() -> Data {
        var output = ""
        if let event, !event.isEmpty {
            output += "event: \(event)\n"
        }
        for line in dataString.split(separator: "\n", omittingEmptySubsequences: false) {
            output += "data: \(line)\n"
        }
        output += "\n"
        return Data(output.utf8)
    }
}

struct SSEDecoder {
    private var buffer = Data()

    mutating func append(_ chunk: Data) -> [SSEFrame] {
        buffer.append(chunk)
        var frames: [SSEFrame] = []

        while let range = frameDelimiterRange(in: buffer) {
            let frameData = Data(buffer[..<range.lowerBound])
            buffer.removeSubrange(..<range.upperBound)
            if let frame = parseFrame(frameData) {
                frames.append(frame)
            }
        }

        return frames
    }

    mutating func flush() -> [SSEFrame] {
        guard !buffer.isEmpty else {
            return []
        }
        defer { buffer.removeAll() }
        if let frame = parseFrame(buffer) {
            return [frame]
        }
        return []
    }

    private func frameDelimiterRange(in data: Data) -> Range<Data.Index>? {
        let lf = data.range(of: Data("\n\n".utf8))
        let crlf = data.range(of: Data("\r\n\r\n".utf8))
        switch (lf, crlf) {
        case let (.some(a), .some(b)):
            return a.lowerBound < b.lowerBound ? a : b
        case let (.some(a), .none):
            return a
        case let (.none, .some(b)):
            return b
        default:
            return nil
        }
    }

    private func parseFrame(_ data: Data) -> SSEFrame? {
        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        var event: String?
        var dataLines: [String] = []
        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("event:") {
                event = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                dataLines.append(String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces))
            }
        }
        guard !dataLines.isEmpty else {
            return nil
        }
        return SSEFrame(event: event, data: Data(dataLines.joined(separator: "\n").utf8))
    }
}

struct CodexCompletedAccumulator {
    private var outputItemsByIndex: [Int: JSONObject] = [:]
    private var fallbackOutputItems: [JSONObject] = []

    mutating func observe(_ payload: JSONObject) -> JSONObject {
        guard let type = JSONHelper.string(payload["type"]) else {
            return payload
        }

        if type == "response.output_item.done",
           let item = JSONHelper.object(payload["item"]),
           JSONHelper.string(item["type"]) != nil {
            if let index = numericIndex(payload["output_index"]) {
                outputItemsByIndex[index] = item
            } else {
                fallbackOutputItems.append(item)
            }
            return payload
        }

        guard type == "response.completed" else {
            return payload
        }

        return patchedCompletedEvent(payload)
    }

    private mutating func patchedCompletedEvent(_ payload: JSONObject) -> JSONObject {
        guard var response = JSONHelper.object(payload["response"]) else {
            return payload
        }
        if let output = JSONHelper.array(response["output"]), !output.isEmpty {
            return payload
        }

        let ordered = outputItemsByIndex.keys.sorted().compactMap { outputItemsByIndex[$0] } + fallbackOutputItems
        guard !ordered.isEmpty else {
            return payload
        }

        response["output"] = ordered
        var patched = payload
        patched["response"] = response
        return patched
    }

    private func numericIndex(_ value: Any?) -> Int? {
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
}

struct ChatStreamTranslator {
    private var responseID = ""
    private var createdAt = 0
    private var model = ""
    private var functionCallIndex = -1
    private var hasReceivedArgumentsDelta = false
    private var hasToolCallAnnounced = false
    private let requestModel: String
    private let originalRequest: JSONObject

    init(requestModel: String, originalRequest: JSONObject) {
        self.requestModel = requestModel
        self.originalRequest = originalRequest
        self.model = requestModel
    }

    mutating func translate(payload: JSONObject) -> [JSONObject] {
        guard let type = JSONHelper.string(payload["type"]) else {
            return []
        }

        if type == "response.created" {
            if let response = JSONHelper.object(payload["response"]) {
                responseID = JSONHelper.string(response["id"]) ?? responseID
                createdAt = intValue(response["created_at"]) ?? createdAt
                model = JSONHelper.string(response["model"]) ?? model
            }
            return []
        }

        var chunk = baseChunk()
        let response = JSONHelper.object(payload["response"])
        if let usage = JSONHelper.object(response?["usage"]),
           let converted = chatUsage(from: usage) {
            chunk["usage"] = converted
        }

        switch type {
        case "response.reasoning_summary_text.delta":
            guard let delta = JSONHelper.string(payload["delta"]) else {
                return []
            }
            chunk["choices"] = [[
                "index": 0,
                "delta": ["role": "assistant", "reasoning_content": delta],
                "finish_reason": NSNull(),
                "native_finish_reason": NSNull()
            ]]
        case "response.reasoning_summary_text.done":
            chunk["choices"] = [[
                "index": 0,
                "delta": ["role": "assistant", "reasoning_content": "\n\n"],
                "finish_reason": NSNull(),
                "native_finish_reason": NSNull()
            ]]
        case "response.output_text.delta":
            guard let delta = JSONHelper.string(payload["delta"]) else {
                return []
            }
            chunk["choices"] = [[
                "index": 0,
                "delta": ["role": "assistant", "content": delta],
                "finish_reason": NSNull(),
                "native_finish_reason": NSNull()
            ]]
        case "response.output_item.added":
            guard let item = JSONHelper.object(payload["item"]),
                  JSONHelper.string(item["type"]) == "function_call" else {
                return []
            }
            functionCallIndex += 1
            hasReceivedArgumentsDelta = false
            hasToolCallAnnounced = true
            chunk["choices"] = [[
                "index": 0,
                "delta": [
                    "role": "assistant",
                    "tool_calls": [[
                        "index": functionCallIndex,
                        "id": JSONHelper.string(item["call_id"]) ?? "",
                        "type": "function",
                        "function": [
                            "name": restoredToolName(JSONHelper.string(item["name"]) ?? ""),
                            "arguments": ""
                        ]
                    ]]
                ],
                "finish_reason": NSNull(),
                "native_finish_reason": NSNull()
            ]]
        case "response.function_call_arguments.delta":
            hasReceivedArgumentsDelta = true
            chunk["choices"] = [[
                "index": 0,
                "delta": [
                    "tool_calls": [[
                        "index": functionCallIndex,
                        "function": ["arguments": JSONHelper.string(payload["delta"]) ?? ""]
                    ]]
                ],
                "finish_reason": NSNull(),
                "native_finish_reason": NSNull()
            ]]
        case "response.function_call_arguments.done":
            guard !hasReceivedArgumentsDelta else {
                return []
            }
            chunk["choices"] = [[
                "index": 0,
                "delta": [
                    "tool_calls": [[
                        "index": functionCallIndex,
                        "function": ["arguments": JSONHelper.string(payload["arguments"]) ?? ""]
                    ]]
                ],
                "finish_reason": NSNull(),
                "native_finish_reason": NSNull()
            ]]
        case "response.output_item.done":
            return translateOutputItemDone(payload, baseChunk: chunk)
        case "response.completed":
            let finishReason = functionCallIndex >= 0 ? "tool_calls" : "stop"
            chunk["choices"] = [[
                "index": 0,
                "delta": [:],
                "finish_reason": finishReason,
                "native_finish_reason": finishReason
            ]]
        case "response.image_generation_call.partial_image":
            guard let b64 = JSONHelper.string(payload["partial_image_b64"]), !b64.isEmpty else {
                return []
            }
            let mime = OpenAICompatTranslator.mimeType(fromCodexOutputFormat: JSONHelper.string(payload["output_format"]))
            chunk["choices"] = [[
                "index": 0,
                "delta": [
                    "role": "assistant",
                    "images": [[
                        "index": 0,
                        "type": "image_url",
                        "image_url": ["url": "data:\(mime);base64,\(b64)"]
                    ]]
                ],
                "finish_reason": NSNull(),
                "native_finish_reason": NSNull()
            ]]
        default:
            return []
        }
        return [chunk]
    }

    private mutating func translateOutputItemDone(_ payload: JSONObject, baseChunk chunk: JSONObject) -> [JSONObject] {
        guard let item = JSONHelper.object(payload["item"]),
              let type = JSONHelper.string(item["type"]) else {
            return []
        }

        if type == "image_generation_call" {
            guard let b64 = JSONHelper.string(item["result"]), !b64.isEmpty else {
                return []
            }
            var imageChunk = chunk
            let mime = OpenAICompatTranslator.mimeType(fromCodexOutputFormat: JSONHelper.string(item["output_format"]))
            imageChunk["choices"] = [[
                "index": 0,
                "delta": [
                    "role": "assistant",
                    "images": [[
                        "index": 0,
                        "type": "image_url",
                        "image_url": ["url": "data:\(mime);base64,\(b64)"]
                    ]]
                ],
                "finish_reason": NSNull(),
                "native_finish_reason": NSNull()
            ]]
            return [imageChunk]
        }

        guard type == "function_call" else {
            return []
        }
        if hasToolCallAnnounced {
            hasToolCallAnnounced = false
            return []
        }

        functionCallIndex += 1
        var toolChunk = chunk
        toolChunk["choices"] = [[
            "index": 0,
            "delta": [
                "role": "assistant",
                "tool_calls": [[
                    "index": functionCallIndex,
                    "id": JSONHelper.string(item["call_id"]) ?? "",
                    "type": "function",
                    "function": [
                        "name": restoredToolName(JSONHelper.string(item["name"]) ?? ""),
                        "arguments": JSONHelper.string(item["arguments"]) ?? ""
                    ]
                ]]
            ],
            "finish_reason": NSNull(),
            "native_finish_reason": NSNull()
        ]]
        return [toolChunk]
    }

    private func baseChunk() -> JSONObject {
        var chunk: JSONObject = [
            "id": responseID,
            "object": "chat.completion.chunk",
            "created": createdAt,
            "model": model.isEmpty ? requestModel : model,
            "choices": [[
                "index": 0,
                "delta": [:],
                "finish_reason": NSNull(),
                "native_finish_reason": NSNull()
            ]]
        ]
        if !requestModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chunk["requested_model"] = requestModel
        }
        return chunk
    }

    private func restoredToolName(_ name: String) -> String {
        let reverse = reverseShortNameMap(from: JSONHelper.array(originalRequest["tools"]))
        return reverse[name] ?? name
    }

    private func reverseShortNameMap(from tools: JSONArray?) -> [String: String] {
        let names = (tools ?? []).compactMap { item -> String? in
            guard let object = JSONHelper.object(item),
                  JSONHelper.string(object["type"]) == "function",
                  let function = JSONHelper.object(object["function"]) else {
                return nil
            }
            return JSONHelper.string(function["name"])
        }
        var used = Set<String>()
        var reverse: [String: String] = [:]
        for name in names {
            var candidate = String(name.prefix(64))
            if name.hasPrefix("mcp__"), let range = name.range(of: "__", options: .backwards) {
                candidate = String(("mcp__" + name[range.upperBound...]).prefix(64))
            }
            var unique = candidate
            var index = 1
            while used.contains(unique) {
                let suffix = "_\(index)"
                unique = String(candidate.prefix(max(0, 64 - suffix.count))) + suffix
                index += 1
            }
            used.insert(unique)
            reverse[unique] = name
        }
        return reverse
    }

    private func intValue(_ value: Any?) -> Int? {
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

    private func chatUsage(from usage: JSONObject?) -> JSONObject? {
        guard let usage else {
            return nil
        }
        var result: JSONObject = [:]
        if let input = usage["input_tokens"] {
            result["prompt_tokens"] = input
        }
        if let output = usage["output_tokens"] {
            result["completion_tokens"] = output
        }
        if let total = usage["total_tokens"] {
            result["total_tokens"] = total
        }
        return result.isEmpty ? nil : result
    }
}
