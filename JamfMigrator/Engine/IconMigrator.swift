//
//  IconMigrator.swift
//  JamfMigrator
//
//  Copies self-service icons: download from the source tenant by icon id,
//  upload to the destination (/pro/v1/icon), then point the freshly written
//  policy or app at the new icon id.
//

import Foundation
import JTKit

actor IconMigrator {
    private let source: JamfPlatform.Client
    private let dest: JamfPlatform.Client
    /// source icon id → destination icon id, so shared icons upload once
    private var copied = [String: String]()

    init(source: JamfPlatform.Client, dest: JamfPlatform.Client) {
        self.source = source
        self.dest = dest
    }

    /// Copies the icon and returns the destination icon id.
    func copy(_ icon: SelfServiceIcon) async throws -> String {
        if let destIconId = copied[icon.sourceId] {
            return destIconId
        }
        // numeric ids download through the API; Jamf Cloud's hash URIs point
        // at the public icon CDN and download directly
        let imageData: Data
        if icon.sourceId.allSatisfy(\.isNumber) {
            imageData = try await source.send(.get, "pro/v1/icon/download/\(icon.sourceId)", accept: "*/*").data
        } else if let url = URL(string: icon.uri), url.scheme == "https" {
            imageData = try await Self.download(url, recorder: source.recorder)
        } else {
            throw JamfPlatform.APIError(.invalidResponse("No usable icon source for \(icon.name)."))
        }
        let upload = multipartBody(fileName: icon.name.isEmpty ? "icon.png" : icon.name, data: imageData)
        let response = try await dest.send(.post, "pro/v1/icon",
                                           body: upload.body,
                                           contentType: upload.contentType)
        let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any]
        guard let id = json?["id"] else {
            throw JamfPlatform.APIError(.invalidResponse("The new icon’s ID is missing from the answer."))
        }
        let destIconId = "\(id)"
        copied[icon.sourceId] = destIconId
        return destIconId
    }

    /// How many redirects an icon download follows.
    static let maximumRedirects = 3

    /// Downloads an icon from its own address (Jamf's icon server), with no
    /// token: JTKit's HTTP client (https only, retries), recorded in the
    /// activity log with the source tenant's requests; as always, the image
    /// itself is not recorded. A redirect to https is followed, also to
    /// another host (nothing secret is sent); one to http is refused.
    static func download(_ url: URL, recorder: RequestRecorder) async throws -> Data {
        var recorder = recorder
        recorder.category = "Icons"
        var next = url
        for _ in 0...maximumRedirects {
            guard next.scheme?.lowercased() == "https", let host = next.host(),
                  let base = URL(string: "https://\(host)\(next.port.map { ":\($0)" } ?? "")") else {
                throw JamfPlatform.APIError(.invalidResponse("The icon’s address isn’t an https:// address."))
            }
            // the client follows nothing itself: every hop is checked here
            let client = HTTPClient(baseURL: base, recorder: recorder, redirects: .refuse)
            do {
                return try await client.send(HTTPRequest(path: next.path(), accept: "*/*", encodedQuery: next.query())).data
            } catch let error as HTTPError {
                guard case .status(let answer, _, _, _) = error, (300..<400).contains(answer.status),
                      let location = answer.headers.first(where: { $0.key.caseInsensitiveCompare("Location") == .orderedSame })?.value,
                      let target = URL(string: location, relativeTo: next)?.absoluteURL else {
                    throw JamfPlatform.APIError(error)
                }
                next = target
            }
        }
        throw JamfPlatform.APIError(.invalidResponse("The icon’s address redirected more than \(maximumRedirects) times."))
    }

    /// Points a freshly written Classic object at the destination icon.
    func assign(iconId: String, displayName: String, to type: ObjectType, destObjectId: String, on client: JamfPlatform.Client) async throws {
        let xml: String
        switch type.key {
        case "policies":
            // an icon-only PUT resets the display name to the policy name;
            // echo it in the same write
            let display = displayName.isEmpty ? ""
                : "<self_service_display_name>\(ClassicXML.escape(displayName))</self_service_display_name>"
            xml = "<policy><self_service><self_service_icon><id>\(iconId)</id></self_service_icon>\(display)</self_service></policy>"
        case "macapplications":
            xml = "<mac_application><self_service><self_service_icon><id>\(iconId)</id></self_service_icon></self_service></mac_application>"
        case "mobiledeviceapplications":
            // the app icon lives in general/icon, not a self_service block
            xml = "<mobile_device_application><general><icon><id>\(iconId)</id></icon></general></mobile_device_application>"
        default: return
        }
        _ = try await client.send(.put, type.api.detailPath(id: destObjectId),
                                  body: Data(xml.utf8), contentType: "application/xml", accept: "application/xml",
                                  privileges: type.access.update)
    }

    private func multipartBody(fileName: String, data: Data) -> (body: Data, contentType: String) {
        let boundary = "JamfMigrator-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".utf8))
        body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return (body, "multipart/form-data; boundary=\(boundary)")
    }
}
