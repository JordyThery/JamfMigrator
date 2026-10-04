//
//  IconMigrator.swift
//  JamfMigrator
//
//  Copies self-service icons: download from the source tenant by icon id,
//  upload to the destination (/pro/v1/icon), then point the freshly written
//  policy or app at the new icon id.
//

import Foundation

actor IconMigrator {
    private let source: PlatformClient
    private let dest: PlatformClient
    /// source icon id → destination icon id, so shared icons upload once
    private var copied = [String: String]()

    init(source: PlatformClient, dest: PlatformClient) {
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
        } else if let url = URL(string: icon.uri), icon.uri.hasPrefix("https://") {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw GatewayError.response(status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                                            errors: [], traceId: nil, body: data)
            }
            imageData = data
        } else {
            throw GatewayError.invalidURL("no usable icon source for \(icon.name)")
        }
        let upload = multipartBody(fileName: icon.name.isEmpty ? "icon.png" : icon.name, data: imageData)
        let response = try await dest.send(.post, "pro/v1/icon",
                                           body: upload.body,
                                           contentType: upload.contentType)
        let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any]
        guard let id = json?["id"] else {
            throw GatewayError.decoding(URLError(.cannotParseResponse))
        }
        let destIconId = "\(id)"
        copied[icon.sourceId] = destIconId
        return destIconId
    }

    /// Points a freshly written Classic object at the destination icon.
    func assign(iconId: String, displayName: String = "", to type: ObjectType, destObjectId: String, on client: PlatformClient) async throws {
        let xml: String
        switch type.key {
        case "policies":
            // an icon-only PUT resets the display name to the policy name
            // (verified live 2026-10-04) — echo it in the same write
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
                                  body: Data(xml.utf8), contentType: "application/xml", accept: "application/xml")
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
