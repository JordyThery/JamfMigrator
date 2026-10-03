//
//  GatewayError.swift
//  JamfMigrator
//
//  Errors from the platform API gateway, decoding the three error body shapes
//  seen live (see docs/OVERHAUL_PLAN.md, "Gateway findings").
//

import Foundation

/// One error entry from a gateway response body.
struct APIErrorDetail: Equatable, Sendable {
    let code: String?
    let field: String?
    let description: String?
}

/// Any failure while talking to the platform API gateway.
enum GatewayError: Error, LocalizedError {
    /// A URL could not be built from the path or query.
    case invalidURL(String)
    /// The network request itself failed (no HTTP response).
    case transport(any Error)
    /// The token endpoint refused the client credentials.
    case tokenFailure(status: Int, detail: String?)
    /// A non-2xx HTTP response, with whatever error body the gateway sent.
    case response(status: Int, errors: [APIErrorDetail], traceId: String?, body: Data)
    /// A 2xx response whose body could not be decoded.
    case decoding(any Error)
    /// A poll helper gave up waiting.
    case pollTimeout(String)

    /// The HTTP status, if this error carries one.
    var status: Int? {
        switch self {
        case .tokenFailure(let status, _), .response(let status, _, _, _): status
        default: nil
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        case .transport(let error):
            return "Network error: \(error.localizedDescription)"
        case .tokenFailure(let status, let detail):
            return "Authentication failed (\(status))\(detail.map { ": \($0)" } ?? "")"
        case .response(let status, let errors, let traceId, let body):
            var message = "HTTP \(status)"
            if !errors.isEmpty {
                message += ": " + errors.map { [$0.code, $0.field, $0.description].compactMap { $0 }.joined(separator: " ") }.joined(separator: "; ")
            } else if let text = String(data: body, encoding: .utf8), !text.isEmpty {
                message += ": \(text.prefix(300))"
            }
            if let traceId { message += " (trace \(traceId))" }
            return message
        case .decoding(let error):
            return "Could not decode the response: \(error.localizedDescription)"
        case .pollTimeout(let what):
            return "Timed out waiting for \(what)"
        }
    }

    /// Builds a `.response` error from a non-2xx body, decoding the three
    /// shapes the gateway uses:
    /// 1. Gateway/Pro: `{httpStatus, traceId, errors: [{code, field, description}]}`
    /// 2. Benchmarks: `{message, error, statusCode, logref}`
    /// 3. A pretty-printed variant of shape 1 (decodes the same way).
    static func from(status: Int, body: Data) -> GatewayError {
        let decoder = JSONDecoder()
        if let shape = try? decoder.decode(GatewayShape.self, from: body), shape.errors != nil || shape.traceId != nil {
            let details = (shape.errors ?? []).map { APIErrorDetail(code: $0.code, field: $0.field, description: $0.description) }
            return .response(status: status, errors: details, traceId: shape.traceId, body: body)
        }
        if let shape = try? decoder.decode(BenchmarkShape.self, from: body), shape.message != nil || shape.error != nil {
            let detail = APIErrorDetail(code: shape.error, field: nil, description: shape.message)
            return .response(status: status, errors: [detail], traceId: shape.logref, body: body)
        }
        return .response(status: status, errors: [], traceId: nil, body: body)
    }

    private struct GatewayShape: Decodable {
        struct Entry: Decodable {
            let code: String?
            let field: String?
            let description: String?
        }
        let httpStatus: Int?
        let traceId: String?
        let errors: [Entry]?
    }

    private struct BenchmarkShape: Decodable {
        let message: String?
        let error: String?
        let statusCode: Int?
        let logref: String?
    }
}
