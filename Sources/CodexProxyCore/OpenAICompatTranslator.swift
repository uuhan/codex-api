import Foundation

public enum OpenAICompatTranslator {
    public static func chatCompletionsToCodex(_ request: JSONObject, model: String, stream: Bool) -> JSONObject {
        let toolNameMap = shortNameMap(from: JSONHelper.array(request["tools"]))
        var output: JSONObject = [
            "instructions": "",
            "stream": stream,
            "model": model,
            "parallel_tool_calls": true,
            "reasoning": [
                "effort": JSONHelper.string(request["reasoning_effort"]) ?? "medium",
                "summary": "auto"
            ],
            "include": ["reasoning.encrypted_content"],
            "input": []
        ]

        if let messages = JSONHelper.array(request["messages"]) {
            output["input"] = messages.flatMap { item -> [Any] in
                guard let message = JSONHelper.object(item) else {
                    return []
                }
                return codexInputItems(fromChatMessage: message, toolNameMap: toolNameMap)
            }
        }

        if let responseFormat = JSONHelper.object(request["response_format"]) {
            output["text"] = responseTextFormat(from: responseFormat, text: JSONHelper.object(request["text"]))
        } else if let text = JSONHelper.object(request["text"]),
                  let verbosity = JSONHelper.string(text["verbosity"]) {
            output["text"] = ["verbosity": verbosity]
        }

        if let tools = JSONHelper.array(request["tools"]) {
            let converted = tools.compactMap { codexTool(from: $0, toolNameMap: toolNameMap) }
            if !converted.isEmpty {
                output["tools"] = converted
            }
        }

        if let toolChoice = request["tool_choice"] {
            output["tool_choice"] = codexToolChoice(from: toolChoice, toolNameMap: toolNameMap)
        }

        output["store"] = false
        return output
    }

    public static func responsesToCodex(_ request: JSONObject, model: String, stream: Bool) -> JSONObject {
        var output = request

        if let input = JSONHelper.string(output["input"]) {
            output["input"] = [[
                "type": "message",
                "role": "user",
                "content": [[
                    "type": "input_text",
                    "text": input
                ]]
            ]]
        }

        output["model"] = model
        output["stream"] = stream
        output["store"] = false
        output["parallel_tool_calls"] = true
        output["include"] = ["reasoning.encrypted_content"]
        output.removeKeys([
            "max_output_tokens",
            "max_completion_tokens",
            "temperature",
            "top_p",
            "truncation",
            "context_management",
            "user",
            "stream_options",
            "previous_response_id",
            "prompt_cache_retention",
            "safety_identifier"
        ])

        if let serviceTier = JSONHelper.string(output["service_tier"]),
           serviceTier != "priority" {
            output.removeValue(forKey: "service_tier")
        }

        if output["instructions"] == nil || output["instructions"] is NSNull {
            output["instructions"] = ""
        }

        if let input = JSONHelper.array(output["input"]) {
            output["input"] = input.map { item in
                guard var object = JSONHelper.object(item) else {
                    return item
                }
                if JSONHelper.string(object["role"]) == "system" {
                    object["role"] = "developer"
                }
                return object
            }
        }

        output = normalizeCodexBuiltinTools(output)
        return output
    }

    public static func ensureImageGenerationTool(in request: JSONObject, model: String) -> JSONObject {
        guard !model.hasSuffix("spark") else {
            return request
        }
        var output = request
        var tools = JSONHelper.array(output["tools"]) ?? []
        let exists = tools.contains { item in
            JSONHelper.string(JSONHelper.object(item)?["type"]) == "image_generation"
        }
        if !exists {
            tools.append(["type": "image_generation", "output_format": "png"])
            output["tools"] = tools
        }
        return output
    }

    public static func chatCompletion(fromCompletedEvent event: JSONObject, originalRequest: JSONObject) -> JSONObject {
        let response = JSONHelper.object(event["response"]) ?? [:]
        let output = JSONHelper.array(response["output"]) ?? []
        var contentText = ""
        var reasoningText = ""
        var toolCalls: [Any] = []
        var images: [Any] = []
        let reverseToolNames = reverseShortNameMap(from: JSONHelper.array(originalRequest["tools"]))

        for item in output {
            guard let object = JSONHelper.object(item),
                  let type = JSONHelper.string(object["type"]) else {
                continue
            }
            switch type {
            case "reasoning":
                if let summaries = JSONHelper.array(object["summary"]) {
                    for summary in summaries {
                        guard let summaryObject = JSONHelper.object(summary),
                              JSONHelper.string(summaryObject["type"]) == "summary_text",
                              let text = JSONHelper.string(summaryObject["text"]) else {
                            continue
                        }
                        reasoningText += text
                    }
                }
            case "message":
                if let parts = JSONHelper.array(object["content"]) {
                    for part in parts {
                        guard let partObject = JSONHelper.object(part),
                              JSONHelper.string(partObject["type"]) == "output_text",
                              let text = JSONHelper.string(partObject["text"]) else {
                            continue
                        }
                        contentText += text
                    }
                }
            case "function_call":
                var name = JSONHelper.string(object["name"]) ?? ""
                if let restored = reverseToolNames[name] {
                    name = restored
                }
                toolCalls.append([
                    "id": JSONHelper.string(object["call_id"]) ?? JSONHelper.string(object["id"]) ?? "",
                    "type": "function",
                    "function": [
                        "name": name,
                        "arguments": JSONHelper.string(object["arguments"]) ?? ""
                    ]
                ])
            case "image_generation_call":
                guard let b64 = JSONHelper.string(object["result"]), !b64.isEmpty else {
                    continue
                }
                images.append([
                    "index": images.count,
                    "type": "image_url",
                    "image_url": [
                        "url": "data:\(mimeType(fromCodexOutputFormat: JSONHelper.string(object["output_format"])));base64,\(b64)"
                    ]
                ])
            default:
                continue
            }
        }

        var message: JSONObject = [
            "role": "assistant",
            "content": contentText.isEmpty ? NSNull() : contentText,
            "reasoning_content": reasoningText.isEmpty ? NSNull() : reasoningText,
            "tool_calls": toolCalls.isEmpty ? NSNull() : toolCalls
        ]
        if !images.isEmpty {
            message["images"] = images
        }

        let finishReason = toolCalls.isEmpty ? "stop" : "tool_calls"
        var result: JSONObject = [
            "id": JSONHelper.string(response["id"]) ?? "chatcmpl-\(UUID().uuidString)",
            "object": "chat.completion",
            "created": JSONHelper.string(response["created_at"]).flatMap(Int.init) ?? Int(Date().timeIntervalSince1970),
            "model": JSONHelper.string(response["model"]) ?? JSONHelper.string(originalRequest["model"]) ?? "",
            "choices": [[
                "index": 0,
                "message": message,
                "finish_reason": finishReason,
                "native_finish_reason": finishReason
            ]]
        ]

        if let usage = chatUsage(from: JSONHelper.object(response["usage"])) {
            result["usage"] = usage
        }
        return result
    }

    public static func responseObject(fromCompletedEvent event: JSONObject) -> JSONObject? {
        JSONHelper.object(event["response"])
    }

    private static func codexInputItems(fromChatMessage message: JSONObject, toolNameMap: [String: String]) -> [Any] {
        let role = JSONHelper.string(message["role"]) ?? "user"
        if role == "tool" {
            return [functionCallOutput(from: message)]
        }

        var items: [Any] = []
        let codexMessage: JSONObject = [
            "type": "message",
            "role": role == "system" ? "developer" : role,
            "content": chatContentParts(from: message["content"], role: role)
        ]

        let contentParts = JSONHelper.array(codexMessage["content"]) ?? []
        if role != "assistant" || !contentParts.isEmpty {
            items.append(codexMessage)
        }

        if role == "assistant", let toolCalls = JSONHelper.array(message["tool_calls"]) {
            for call in toolCalls {
                guard let callObject = JSONHelper.object(call),
                      JSONHelper.string(callObject["type"]) == "function",
                      let function = JSONHelper.object(callObject["function"]) else {
                    continue
                }
                let originalName = JSONHelper.string(function["name"]) ?? ""
                items.append([
                    "type": "function_call",
                    "call_id": JSONHelper.string(callObject["id"]) ?? "",
                    "name": toolNameMap[originalName] ?? shortenNameIfNeeded(originalName),
                    "arguments": JSONHelper.string(function["arguments"]) ?? ""
                ])
            }
        }

        return items
    }

    private static func chatContentParts(from content: Any?, role: String) -> [Any] {
        if let text = JSONHelper.string(content), !text.isEmpty {
            return [[
                "type": role == "assistant" ? "output_text" : "input_text",
                "text": text
            ]]
        }
        guard let array = JSONHelper.array(content) else {
            return []
        }
        return array.compactMap { item in
            guard let object = JSONHelper.object(item),
                  let type = JSONHelper.string(object["type"]) else {
                return nil
            }
            switch type {
            case "text":
                return [
                    "type": role == "assistant" ? "output_text" : "input_text",
                    "text": JSONHelper.string(object["text"]) ?? ""
                ]
            case "image_url":
                guard role == "user", let imageURL = JSONHelper.object(object["image_url"]) else {
                    return nil
                }
                if let url = JSONHelper.string(imageURL["url"]) {
                    return ["type": "input_image", "image_url": url]
                }
                return nil
            case "file":
                guard role == "user", let file = JSONHelper.object(object["file"]) else {
                    return nil
                }
                var part: JSONObject = ["type": "input_file"]
                if let fileData = JSONHelper.string(file["file_data"]) {
                    part["file_data"] = fileData
                }
                if let fileID = JSONHelper.string(file["file_id"]) {
                    part["file_id"] = fileID
                }
                if let fileURL = JSONHelper.string(file["file_url"]) {
                    part["file_url"] = fileURL
                }
                if let filename = JSONHelper.string(file["filename"]) {
                    part["filename"] = filename
                }
                return part.count > 1 ? part : nil
            default:
                return nil
            }
        }
    }

    private static func functionCallOutput(from message: JSONObject) -> JSONObject {
        var output: JSONObject = [
            "type": "function_call_output",
            "call_id": JSONHelper.string(message["tool_call_id"]) ?? ""
        ]
        let content = message["content"]
        if let text = JSONHelper.string(content) {
            output["output"] = text
        } else if let parts = JSONHelper.array(content) {
            output["output"] = parts.map { part -> Any in
                guard let object = JSONHelper.object(part),
                      let type = JSONHelper.string(object["type"]) else {
                    return ["type": "input_text", "text": JSONHelper.compactString(part)]
                }
                switch type {
                case "text":
                    return ["type": "input_text", "text": JSONHelper.string(object["text"]) ?? ""]
                case "image_url":
                    let imageURL = JSONHelper.object(object["image_url"]) ?? [:]
                    var out: JSONObject = ["type": "input_image"]
                    if let url = JSONHelper.string(imageURL["url"]) {
                        out["image_url"] = url
                    }
                    if let fileID = JSONHelper.string(imageURL["file_id"]) {
                        out["file_id"] = fileID
                    }
                    if let detail = JSONHelper.string(imageURL["detail"]) {
                        out["detail"] = detail
                    }
                    return out.count > 1 ? out : ["type": "input_text", "text": JSONHelper.compactString(part)]
                case "file":
                    let file = JSONHelper.object(object["file"]) ?? [:]
                    var out: JSONObject = ["type": "input_file"]
                    if let fileID = JSONHelper.string(file["file_id"]) {
                        out["file_id"] = fileID
                    }
                    if let fileData = JSONHelper.string(file["file_data"]) {
                        out["file_data"] = fileData
                    }
                    if let fileURL = JSONHelper.string(file["file_url"]) {
                        out["file_url"] = fileURL
                    }
                    if let filename = JSONHelper.string(file["filename"]) {
                        out["filename"] = filename
                    }
                    return out.count > 1 ? out : ["type": "input_text", "text": JSONHelper.compactString(part)]
                default:
                    return ["type": "input_text", "text": JSONHelper.compactString(part)]
                }
            }
        } else {
            output["output"] = content.map(JSONHelper.compactString) ?? ""
        }
        return output
    }

    private static func responseTextFormat(from responseFormat: JSONObject, text: JSONObject?) -> JSONObject {
        var result: JSONObject = [:]
        let type = JSONHelper.string(responseFormat["type"]) ?? ""
        if type == "text" {
            result["format"] = ["type": "text"]
        } else if type == "json_schema", let schema = JSONHelper.object(responseFormat["json_schema"]) {
            var format: JSONObject = ["type": "json_schema"]
            if let name = schema["name"] {
                format["name"] = name
            }
            if let strict = schema["strict"] {
                format["strict"] = strict
            }
            if let rawSchema = schema["schema"] {
                format["schema"] = rawSchema
            }
            result["format"] = format
        }
        if let verbosity = JSONHelper.string(text?["verbosity"]) {
            result["verbosity"] = verbosity
        }
        return result
    }

    private static func codexTool(from item: Any, toolNameMap: [String: String]) -> Any? {
        guard let object = JSONHelper.object(item),
              let type = JSONHelper.string(object["type"]) else {
            return nil
        }
        if type != "function" {
            return object
        }
        guard let function = JSONHelper.object(object["function"]) else {
            return nil
        }
        let originalName = JSONHelper.string(function["name"]) ?? ""
        var out: JSONObject = [
            "type": "function",
            "name": toolNameMap[originalName] ?? shortenNameIfNeeded(originalName)
        ]
        if let description = function["description"] {
            out["description"] = description
        }
        if let parameters = function["parameters"] {
            out["parameters"] = parameters
        }
        if let strict = function["strict"] {
            out["strict"] = strict
        }
        return out
    }

    private static func codexToolChoice(from value: Any, toolNameMap: [String: String]) -> Any {
        if let string = JSONHelper.string(value) {
            return string
        }
        guard let object = JSONHelper.object(value),
              let type = JSONHelper.string(object["type"]) else {
            return value
        }
        guard type == "function" else {
            return object
        }
        let function = JSONHelper.object(object["function"])
        let name = JSONHelper.string(function?["name"]) ?? ""
        var choice: JSONObject = ["type": "function"]
        if !name.isEmpty {
            choice["name"] = toolNameMap[name] ?? shortenNameIfNeeded(name)
        }
        return choice
    }

    private static func normalizeCodexBuiltinTools(_ request: JSONObject) -> JSONObject {
        var output = request
        if let tools = JSONHelper.array(output["tools"]) {
            output["tools"] = tools.map { item in
                guard var object = JSONHelper.object(item),
                      let type = JSONHelper.string(object["type"]),
                      let normalized = normalizedCodexBuiltinToolType(type) else {
                    return item
                }
                object["type"] = normalized
                return object
            }
        }
        if var choice = JSONHelper.object(output["tool_choice"]),
           let type = JSONHelper.string(choice["type"]),
           let normalized = normalizedCodexBuiltinToolType(type) {
            choice["type"] = normalized
            output["tool_choice"] = choice
        }
        return output
    }

    private static func normalizedCodexBuiltinToolType(_ type: String) -> String? {
        switch type {
        case "web_search_preview", "web_search_preview_2025_03_11":
            return "web_search"
        default:
            return nil
        }
    }

    private static func shortNameMap(from tools: JSONArray?) -> [String: String] {
        let names = (tools ?? []).compactMap { item -> String? in
            guard let object = JSONHelper.object(item),
                  JSONHelper.string(object["type"]) == "function",
                  let function = JSONHelper.object(object["function"]) else {
                return nil
            }
            return JSONHelper.string(function["name"])
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

    private static func chatUsage(from usage: JSONObject?) -> JSONObject? {
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
        if let details = JSONHelper.object(usage["input_tokens_details"]),
           let cached = details["cached_tokens"] {
            result["prompt_tokens_details"] = ["cached_tokens": cached]
        }
        if let details = JSONHelper.object(usage["output_tokens_details"]),
           let reasoning = details["reasoning_tokens"] {
            result["completion_tokens_details"] = ["reasoning_tokens": reasoning]
        }
        return result.isEmpty ? nil : result
    }

    static func mimeType(fromCodexOutputFormat outputFormat: String?) -> String {
        let raw = (outputFormat ?? "").lowercased()
        if raw.contains("/") {
            return raw
        }
        switch raw {
        case "jpg", "jpeg":
            return "image/jpeg"
        case "webp":
            return "image/webp"
        case "gif":
            return "image/gif"
        default:
            return "image/png"
        }
    }
}
