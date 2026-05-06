import XCTest
@testable import CodexProxyCore

final class TranslatorTests: XCTestCase {
    func testChatCompletionsToolCallMapsToCodexInputItems() throws {
        let request = try object("""
        {
          "model": "gpt-5-codex",
          "messages": [
            {"role": "system", "content": "You are concise."},
            {"role": "user", "content": "Weather in Paris?"},
            {
              "role": "assistant",
              "content": null,
              "tool_calls": [
                {
                  "id": "call_1",
                  "type": "function",
                  "function": {"name": "get_weather", "arguments": "{\\"city\\":\\"Paris\\"}"}
                }
              ]
            },
            {"role": "tool", "tool_call_id": "call_1", "content": "sunny"}
          ],
          "tools": [
            {
              "type": "function",
              "function": {
                "name": "get_weather",
                "description": "Get weather",
                "parameters": {"type": "object"}
              }
            }
          ]
        }
        """)

        let output = OpenAICompatTranslator.chatCompletionsToCodex(request, model: "gpt-5-codex", stream: true)
        let input = try XCTUnwrap(output["input"] as? [Any])
        XCTAssertEqual(input.count, 4)
        XCTAssertEqual((input[0] as? JSONObject)?["role"] as? String, "developer")
        XCTAssertEqual((input[1] as? JSONObject)?["role"] as? String, "user")
        XCTAssertEqual((input[2] as? JSONObject)?["type"] as? String, "function_call")
        XCTAssertEqual((input[2] as? JSONObject)?["call_id"] as? String, "call_1")
        XCTAssertEqual((input[3] as? JSONObject)?["type"] as? String, "function_call_output")
        XCTAssertEqual((input[3] as? JSONObject)?["output"] as? String, "sunny")
    }

    func testResponsesRequestNormalizesCodexUnsupportedFields() throws {
        let request = try object("""
        {
          "model": "gpt-5-codex",
          "input": "hello",
          "stream": false,
          "temperature": 0.2,
          "top_p": 0.9,
          "user": "u",
          "tools": [{"type": "web_search_preview"}],
          "tool_choice": {"type": "web_search_preview_2025_03_11"}
        }
        """)

        let output = OpenAICompatTranslator.responsesToCodex(request, model: "gpt-5-codex", stream: true)
        XCTAssertNil(output["temperature"])
        XCTAssertNil(output["top_p"])
        XCTAssertNil(output["user"])
        XCTAssertEqual(output["stream"] as? Bool, true)
        let input = try XCTUnwrap(output["input"] as? [Any])
        XCTAssertEqual((input.first as? JSONObject)?["role"] as? String, "user")
        XCTAssertEqual(((output["tools"] as? [Any])?.first as? JSONObject)?["type"] as? String, "web_search")
        XCTAssertEqual((output["tool_choice"] as? JSONObject)?["type"] as? String, "web_search")
    }

    func testCompletedAccumulatorPatchesEmptyResponseOutput() throws {
        var accumulator = CodexCompletedAccumulator()
        _ = accumulator.observe(try object("""
        {"type":"response.output_item.done","output_index":0,"item":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"hello"}]}}
        """))
        let patched = accumulator.observe(try object("""
        {"type":"response.completed","response":{"id":"resp_1","output":[]}}
        """))

        let response = try XCTUnwrap(patched["response"] as? JSONObject)
        let output = try XCTUnwrap(response["output"] as? [Any])
        XCTAssertEqual(output.count, 1)
        XCTAssertEqual((output.first as? JSONObject)?["type"] as? String, "message")
    }

    func testCompletedEventConvertsToChatCompletion() throws {
        let event = try object("""
        {
          "type": "response.completed",
          "response": {
            "id": "resp_1",
            "created_at": 1700000000,
            "model": "gpt-5-codex",
            "status": "completed",
            "usage": {"input_tokens": 5, "output_tokens": 7, "total_tokens": 12},
            "output": [
              {"type": "reasoning", "summary": [{"type": "summary_text", "text": "thinking"}]},
              {"type": "message", "content": [{"type": "output_text", "text": "done"}], "role": "assistant"}
            ]
          }
        }
        """)

        let output = OpenAICompatTranslator.chatCompletion(fromCompletedEvent: event, originalRequest: ["model": "gpt-5-codex"])
        XCTAssertEqual(output["id"] as? String, "resp_1")
        let choices = try XCTUnwrap(output["choices"] as? [Any])
        let first = try XCTUnwrap(choices.first as? JSONObject)
        let message = try XCTUnwrap(first["message"] as? JSONObject)
        XCTAssertEqual(message["content"] as? String, "done")
        XCTAssertEqual(message["reasoning_content"] as? String, "thinking")
        XCTAssertEqual((output["usage"] as? JSONObject)?["total_tokens"] as? Int, 12)
    }

    func testChatCompletionExposesActualAndRequestedModels() throws {
        let event = try object("""
        {
          "type": "response.completed",
          "response": {
            "id": "resp_1",
            "created_at": 1700000000,
            "model": "gpt-5.4",
            "status": "completed",
            "output": [
              {"type": "message", "content": [{"type": "output_text", "text": "done"}], "role": "assistant"}
            ]
          }
        }
        """)

        let output = OpenAICompatTranslator.chatCompletion(fromCompletedEvent: event, originalRequest: ["model": "gpt-5.3-codex"])

        XCTAssertEqual(output["model"] as? String, "gpt-5.4")
        XCTAssertEqual(output["requested_model"] as? String, "gpt-5.3-codex")
    }

    func testResponseObjectExposesActualAndRequestedModels() throws {
        let event = try object("""
        {
          "type": "response.completed",
          "response": {
            "id": "resp_1",
            "model": "gpt-5.4",
            "output": []
          }
        }
        """)

        let response = try XCTUnwrap(OpenAICompatTranslator.responseObject(fromCompletedEvent: event, requestedModel: "gpt-5.3-codex"))

        XCTAssertEqual(response["model"] as? String, "gpt-5.4")
        XCTAssertEqual(response["requested_model"] as? String, "gpt-5.3-codex")
    }

    func testResponseEventExposesActualAndRequestedModels() throws {
        let event = try object("""
        {
          "type": "response.created",
          "response": {
            "id": "resp_1",
            "model": "gpt-5.4",
            "output": []
          }
        }
        """)

        let output = OpenAICompatTranslator.responseEventWithRequestedModel(event, requestedModel: "gpt-5.3-codex")
        let response = try XCTUnwrap(output["response"] as? JSONObject)

        XCTAssertEqual(response["model"] as? String, "gpt-5.4")
        XCTAssertEqual(response["requested_model"] as? String, "gpt-5.3-codex")
    }

    func testChatStreamExposesActualAndRequestedModels() throws {
        var translator = ChatStreamTranslator(requestModel: "gpt-5.3-codex", originalRequest: ["model": "gpt-5.3-codex"])

        _ = translator.translate(payload: try object("""
        {
          "type": "response.created",
          "response": {
            "id": "resp_1",
            "created_at": 1700000000,
            "model": "gpt-5.4"
          }
        }
        """))
        let chunks = translator.translate(payload: try object("""
        {
          "type": "response.output_text.delta",
          "delta": "hi"
        }
        """))

        let first = try XCTUnwrap(chunks.first)
        XCTAssertEqual(first["model"] as? String, "gpt-5.4")
        XCTAssertEqual(first["requested_model"] as? String, "gpt-5.3-codex")
    }

    private func object(_ string: String) throws -> JSONObject {
        try JSONHelper.object(from: Data(string.utf8))
    }
}
