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
        let image = try await source.send(.get, "pro/v1/icon/download/\(icon.sourceId)", accept: "*/*")
        let upload = multipartBody(fileName: icon.name.isEmpty ? "icon.png" : icon.name, data: image.data)
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
    func assign(iconId: String, to type: ObjectType, destObjectId: String, on client: PlatformClient) async throws {
        let rootTag: String
        switch type.key {
        case "policies": rootTag = "policy"
        case "macapplications": rootTag = "mac_application"
        case "mobiledeviceapplications": rootTag = "mobile_device_application"
        default: return
        }
        let xml = "<\(rootTag)><self_service><self_service_icon><id>\(iconId)</id></self_service_icon></self_service></\(rootTag)>"
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
