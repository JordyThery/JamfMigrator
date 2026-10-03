//
//  JamfPro.swift
//  JamfMigrator
//
//  Bridges the legacy UI onto the platform API TokenProvider. Only the
//  gateway with client credentials is supported; Basic auth, user/password
//  tokens and /api/oauth/token are gone. This file disappears with the rest
//  of the legacy UI in Phase 7.
//

import Foundation
import AppKit

class JamfPro {

    static let shared = JamfPro()

    /// One provider per server, replaced when the server or credentials change.
    private var providers = [String: (key: String, provider: TokenProvider)]()
    private var renewTasks = [String: Task<Void, Never>]()

    func getToken(whichServer: String, serverUrl: String, completion: @escaping (_ authResult: (Int, String)) -> Void) {

        logFunctionCall()

        // local source (file import), wipe runs and export-only don't talk to that server
        if (whichServer == "source" && (WipeData.state.on || JamfProServer.importFiles == 1)) || (whichServer == "dest" && export.saveOnly) {
            completion((200, "success"))
            return
        }
        if serverUrl.prefix(4) != "http" {
            completion((0, "skipped"))
            return
        }
        guard ApiRequest.isPlatformGateway(serverUrl) else {
            WriteToLog.shared.message("[JamfPro.getToken] \(serverUrl) is not a platform API gateway URL (us|eu|apac.api.jamfcloud.com)")
            if Setting.fullGUI {
                _ = Alert.shared.display(header: "\(serverUrl)", message: "Only the Jamf platform API gateway is supported:\nhttps://us.api.jamfcloud.com (or eu/apac)", secondButton: "")
            }
            completion((0, "failed"))
            return
        }

        let clientId = (whichServer == "source") ? JamfProServer.sourceUser : JamfProServer.destUser
        let secret   = (whichServer == "source") ? JamfProServer.sourcePwd : JamfProServer.destPwd
        let baseUrl  = ApiRequest.serverRoot(serverUrl)
        guard let tokenURL = URL(string: "\(baseUrl)/auth/token") else {
            completion((500, "failed"))
            return
        }

        let provider = provider(for: whichServer, tokenURL: tokenURL, clientId: clientId, secret: secret)

        Task {
            do {
                let token = try await provider.validToken()
                await MainActor.run {
                    JamfProServer.validToken[whichServer]   = true
                    JamfProServer.authCreds[whichServer]    = token
                    JamfProServer.accessToken[whichServer]  = token
                    JamfProServer.tokenCreated[whichServer] = Date()
                    if whichServer == "source" {
                        JamfProServer.source = baseUrl
                    } else {
                        JamfProServer.destination = baseUrl
                    }
                    if WipeData.state.on && whichServer == "dest" {
                        JamfProServer.validToken["source"]    = true
                        JamfProServer.authCreds["source"]     = token
                        JamfProServer.accessToken["source"]   = token
                        JamfProServer.environmentId["source"] = JamfProServer.environmentId[whichServer]
                    }
                    WriteToLog.shared.message("[JamfPro.getToken] new token created for \(whichServer): \(baseUrl)")
                    self.scheduleRenewal(whichServer: whichServer, serverUrl: serverUrl)
                    self.fetchVersionIfNeeded(whichServer: whichServer, token: token, completion: completion)
                }
            } catch {
                let status = (error as? GatewayError)?.status ?? 0
                WriteToLog.shared.message("[JamfPro.getToken] failed to authenticate to \(baseUrl): \(error.localizedDescription)")
                await MainActor.run {
                    JamfProServer.validToken[whichServer] = false
                    if Setting.fullGUI {
                        _ = Alert.shared.display(header: "\(baseUrl)", message: "Failed to authenticate to \(baseUrl). \nStatus Code: \(status)", secondButton: "")
                    } else {
                        NSApplication.shared.terminate(self)
                    }
                    completion((status, "failed"))
                }
            }
        }
    }

    private func provider(for whichServer: String, tokenURL: URL, clientId: String, secret: String) -> TokenProvider {
        let key = "\(tokenURL.absoluteString)|\(clientId)|\(secret.hashValue)"
        if let existing = providers[whichServer], existing.key == key {
            return existing.provider
        }
        let provider = TokenProvider(credentials: {
            TokenProvider.Credentials(tokenURL: tokenURL, clientId: clientId, clientSecret: secret)
        })
        providers[whichServer] = (key, provider)
        return provider
    }

    /// The legacy engine reads JamfProServer.accessToken directly, so keep it
    /// fresh while a migration is running. Phase 2 moves the engine onto
    /// PlatformClient and this goes away.
    private func scheduleRenewal(whichServer: String, serverUrl: String) {
        renewTasks[whichServer]?.cancel()
        guard let provider = providers[whichServer]?.provider else { return }
        renewTasks[whichServer] = Task { [weak self] in
            while !Task.isCancelled && !migrationComplete.isDone {
                try? await Task.sleep(for: .seconds(660))   // 11 min, inside the 15 min lifetime
                guard !Task.isCancelled, !migrationComplete.isDone else { return }
                guard let token = try? await provider.validToken() else { continue }
                _ = self
                await MainActor.run {
                    JamfProServer.authCreds[whichServer]   = token
                    JamfProServer.accessToken[whichServer] = token
                    if WipeData.state.on && whichServer == "dest" {
                        JamfProServer.authCreds["source"]   = token
                        JamfProServer.accessToken["source"] = token
                    }
                }
            }
        }
    }

    private func fetchVersionIfNeeded(whichServer: String, token: String, completion: @escaping (_ authResult: (Int, String)) -> Void) {
        guard JamfProServer.version[whichServer] == "" else {
            completion((200, "success"))
            return
        }
        Jpapi.shared.action(whichServer: whichServer, endpoint: "jamf-pro-version", apiData: [:], id: "", token: token, method: "GET") { (result: [String: Any]) in
            guard let versionString = result["version"] as? String, versionString != "" else {
                WriteToLog.shared.message("[JamfPro.getToken] failed to get version information from the \(whichServer) server")
                JamfProServer.validToken[whichServer] = false
                if Setting.fullGUI {
                    _ = Alert.shared.display(header: "Attention", message: "Failed to get version information from the \(whichServer) server", secondButton: "")
                }
                completion((0, "failed"))
                return
            }
            WriteToLog.shared.message("[JamfPro.getToken] \(whichServer) Jamf Pro version: \(versionString)")
            JamfProServer.version[whichServer] = versionString
            let parts = versionString.components(separatedBy: ".")
            if parts.count > 2 {
                JamfProServer.majorVersion = Int(parts[0]) ?? 0
                JamfProServer.minorVersion = Int(parts[1]) ?? 0
                let patch = parts[2].components(separatedBy: "-")
                JamfProServer.patchVersion = Int(patch[0]) ?? 0
                if patch.count > 1 {
                    JamfProServer.build = patch[1]
                }
            }
            completion((200, "success"))
        }
    }
}
