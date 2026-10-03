//
//  TransformerTests.swift
//  JamfMigratorTests
//

import Foundation
import Testing
@testable import JamfMigrator

private func context(action: TransformAction = .create) -> TransformContext {
    var context = TransformContext(action: action)
    context.destIdsByName = [
        "categories": ["Utilities": "77"],
        "sites": ["HQ": "9"],
        "ldapservers": ["Corp LDAP": "42"],
        "patchsoftwaretitles": ["Google Chrome": "55"],
        "packages": ["Chrome-120.pkg": "31"],
        "smartcomputergroups": ["All Laptops": "12"],
    ]
    context.sourceNamesById = [
        "categories": ["3": "Utilities"],
        "sites": ["2": "HQ"],
        "packages": ["8": "Chrome-120.pkg"],
        "patchsoftwaretitles": ["5": "Google Chrome"],
    ]
    context.includedTypes = Set(ObjectRegistry.types.map(\.key))
    return context
}

private func xmlBody(_ outcome: TransformOutcome) throws -> String {
    guard case .write(let object) = outcome else {
        Issue.record("expected .write, got \(outcome)")
        throw GatewayError.invalidURL("blocked")
    }
    return String(decoding: object.body, as: UTF8.self)
}

private func jsonBody(_ outcome: TransformOutcome) throws -> [String: Any] {
    guard case .write(let object) = outcome else {
        Issue.record("expected .write, got \(outcome)")
        throw GatewayError.invalidURL("blocked")
    }
    return try JSONSerialization.jsonObject(with: object.body) as! [String: Any]
}

struct ClassicTransformerTests {

    @Test func idsAreStrippedEverywhere() throws {
        let xml = "<site><id>4</id><name>HQ</name></site>"
        let out = try xmlBody(ClassicTransformer.transform(type: ObjectRegistry.type("sites")!, xml: xml, context: context()))
        #expect(!out.contains("<id>"))
        #expect(out.contains("<name>HQ</name>"))
    }

    @Test func networkSegmentsLoseServerReferences() throws {
        let xml = """
        <network_segment><id>1</id><name>Office</name>\
        <distribution_server>old-server</distribution_server>\
        <distribution_point>Cloud Distribution Point</distribution_point>\
        <url>https://jcds.example.com</url>\
        <swu_server>sus.example.com</swu_server></network_segment>
        """
        var ctx = context()
        ctx.includedTypes.remove("softwareupdateservers")
        let out = try xmlBody(ClassicTransformer.transform(type: ObjectRegistry.type("networksegments")!, xml: xml, context: ctx))
        #expect(out.contains("<distribution_server/>"))
        #expect(out.contains("<url/>"))
        #expect(out.contains("<swu_server/>"))
    }

    @Test func ldapServersGetTheStoredSecret() throws {
        let xml = #"<ldap_server><name>Corp LDAP</name><password_sha256 since="9.23">abc123</password_sha256></ldap_server>"#
        var ctx = context()
        ctx.secrets["ldap"] = "re@l-Secret"
        let out = try xmlBody(ClassicTransformer.transform(type: ObjectRegistry.type("ldapservers")!, xml: xml, context: ctx))
        #expect(out.contains("<password>re@l-Secret</password>"))
        #expect(!out.contains("password_sha256"))
    }

    @Test func directoryBindingsFallBackToThePlaceholder() throws {
        let xml = #"<directory_binding><name>AD</name><password_sha256 since="9.23">abc</password_sha256></directory_binding>"#
        let outcome = ClassicTransformer.transform(type: ObjectRegistry.type("directorybindings")!, xml: xml, context: context())
        let out = try xmlBody(outcome)
        #expect(out.contains("<password>\(placeholderSecret)</password>"))
        guard case .write(let object) = outcome else { return }
        #expect(!object.warnings.isEmpty)
    }

    @Test func jamfGroupsRemapTheirLdapServer() throws {
        let xml = "<group><name>Admins</name><ldap_server><id>7</id><name>Corp LDAP</name></ldap_server></group>"
        let out = try xmlBody(ClassicTransformer.transform(type: ObjectRegistry.type("jamfgroups")!, xml: xml, context: context()))
        #expect(out.contains("<ldap_server><id>42</id></ldap_server>"))
    }

    @Test func jamfGroupsBlockOnAMissingLdapServer() {
        let xml = "<group><name>Admins</name><ldap_server><name>Unknown LDAP</name></ldap_server></group>"
        guard case .blocked(let reason) = ClassicTransformer.transform(type: ObjectRegistry.type("jamfgroups")!, xml: xml, context: context()) else {
            Issue.record("expected .blocked")
            return
        }
        #expect(reason.contains("Unknown LDAP"))
    }

    @Test func asmClassesAreBlocked() {
        let xml = "<class><name>Math</name><source>Apple School Manager</source></class>"
        guard case .blocked = ClassicTransformer.transform(type: ObjectRegistry.type("classes")!, xml: xml, context: context()) else {
            Issue.record("expected .blocked")
            return
        }
    }

    @Test func fileVaultProfilesAreBlocked() {
        let xml = "<os_x_configuration_profile><general><name>FV</name></general><payloads>com.apple.security.FDERecoveryKeyEscrow</payloads></os_x_configuration_profile>"
        guard case .blocked(let reason) = ClassicTransformer.transform(type: ObjectRegistry.type("osxconfigurationprofiles")!, xml: xml, context: context()) else {
            Issue.record("expected .blocked")
            return
        }
        #expect(reason.contains("FileVault"))
    }

    @Test func profileUpdatesKeepTheDestinationUUID() throws {
        let xml = "<os_x_configuration_profile><general><name>Wi-Fi</name><uuid>SRC-UUID</uuid></general><payloads>PayloadUUID SRC-UUID</payloads></os_x_configuration_profile>"
        var ctx = context(action: .update(destId: "3"))
        ctx.destProfileUUID = "DEST-UUID"
        let out = try xmlBody(ClassicTransformer.transform(type: ObjectRegistry.type("osxconfigurationprofiles")!, xml: xml, context: ctx))
        #expect(!out.contains("SRC-UUID"))
        #expect(out.contains("DEST-UUID"))
    }

    @Test func policiesExtractTheIconAndScrubSecrets() throws {
        let xml = """
        <policy><general><id>10</id><name>Install Chrome</name></general>\
        <self_service><self_service_icon><id>66</id><filename>chrome.png</filename>\
        <uri>https://src.jamfcloud.com/iconservlet?id=66</uri></self_service_icon></self_service>\
        <account_maintenance><password_sha256 since="9.23">hash</password_sha256></account_maintenance>\
        <limit_to_users><user_groups/></limit_to_users></policy>
        """
        let outcome = ClassicTransformer.transform(type: ObjectRegistry.type("policies")!, xml: xml, context: context())
        guard case .write(let object) = outcome else {
            Issue.record("expected .write")
            return
        }
        let out = String(decoding: object.body, as: UTF8.self)
        #expect(object.icon == SelfServiceIcon(name: "chrome.png", sourceId: "66"))
        #expect(!out.contains("self_service_icon"))
        #expect(!out.contains("limit_to_users"))
        #expect(out.contains("<password>jamfchangeme</password>"))
    }

    @Test func appsResetVPP() throws {
        let xml = "<mac_application><general><name>Numbers</name></general><vpp><assign_vpp_device_based_licenses>true</assign_vpp_device_based_licenses><vpp_admin_account_id>3</vpp_admin_account_id></vpp></mac_application>"
        let out = try xmlBody(ClassicTransformer.transform(type: ObjectRegistry.type("macapplications")!, xml: xml, context: context()))
        #expect(out.contains("<vpp_admin_account_id>-1</vpp_admin_account_id>"))
        #expect(out.contains("<assign_vpp_device_based_licenses>false</assign_vpp_device_based_licenses>"))
    }

    @Test func patchPoliciesCreateUnderTheDestinationTitle() throws {
        let xml = "<patch_policy><general><id>2</id><name>Chrome Stable</name></general><software_title_configuration_id>5</software_title_configuration_id></patch_policy>"
        let outcome = ClassicTransformer.transform(type: ObjectRegistry.type("patchpolicies")!, xml: xml, context: context())
        guard case .write(let object) = outcome else {
            Issue.record("expected .write")
            return
        }
        #expect(object.createPathOverride == "proclassic/patchpolicies/softwaretitleconfig/id/55")
        #expect(!String(decoding: object.body, as: UTF8.self).contains("software_title_configuration_id"))
    }

    @Test func iconIdParsing() {
        #expect(ClassicTransformer.iconId(fromUri: "https://x/iconservlet?id=123") == "123")
        #expect(ClassicTransformer.iconId(fromUri: "https://x/icon?id=9&size=300") == "9")
        #expect(ClassicTransformer.iconId(fromUri: "https://x/icons/456") == "456")
        #expect(ClassicTransformer.iconId(fromUri: "") == "0")
    }
}

struct ProTransformerTests {

    @Test func idsAndNullsAreStripped() throws {
        let json: [String: Any] = ["id": "4", "name": "Utilities", "note": NSNull()]
        let out = try jsonBody(ProTransformer.transform(type: ObjectRegistry.type("categories")!, json: json, context: context()))
        #expect(out["id"] == nil)
        #expect(out["note"] == nil)
        #expect(out["name"] as? String == "Utilities")
    }

    @Test func patchEAsAreBlocked() {
        let json: [String: Any] = ["id": "1", "name": "Chrome Version",
                                   "description": "Extension Attribute provided by JAMF Nation patch service"]
        guard case .blocked = ProTransformer.transform(type: ObjectRegistry.type("computerextensionattributes")!, json: json, context: context()) else {
            Issue.record("expected .blocked")
            return
        }
    }

    @Test func scriptsRemapTheirCategory() throws {
        let json: [String: Any] = ["id": "9", "name": "fix.sh", "categoryId": "3", "categoryName": "Utilities"]
        let out = try jsonBody(ProTransformer.transform(type: ObjectRegistry.type("scripts")!, json: json, context: context()))
        #expect(out["categoryId"] as? String == "77")
    }

    @Test func packagesLoseHashesAndRemapCategory() throws {
        let json: [String: Any] = ["id": "8", "packageName": "Chrome-120.pkg", "fileName": "Chrome-120.pkg",
                                   "categoryId": "3", "md5": "abc", "hashValue": "def", "size": 1234]
        let out = try jsonBody(ProTransformer.transform(type: ObjectRegistry.type("packages")!, json: json, context: context()))
        #expect(out["md5"] == nil)
        #expect(out["hashValue"] == nil)
        #expect(out["size"] == nil)
        #expect(out["categoryId"] as? String == "77")
    }

    @Test func staticGroupsAreCreatedEmpty() throws {
        let json: [String: Any] = ["id": "3", "name": "Lab Macs", "siteId": "2", "computerIds": ["1", "2", "3"]]
        let outcome = ProTransformer.transform(type: ObjectRegistry.type("staticcomputergroups")!, json: json, context: context())
        let out = try jsonBody(outcome)
        #expect(out["computerIds"] == nil)
        #expect(out["siteId"] as? String == "9")
        guard case .write(let object) = outcome else { return }
        #expect(object.warnings.contains { $0.contains("inventory") })
    }

    @Test func patchTitlesRemapEverything() throws {
        let json: [String: Any] = [
            "id": "5", "displayName": "Google Chrome", "categoryName": "Utilities", "siteName": "HQ",
            "packages": [["packageId": "8", "version": "120.0"], ["packageId": "99", "version": "1.0"]],
        ]
        let outcome = ProTransformer.transform(type: ObjectRegistry.type("patchsoftwaretitles")!, json: json, context: context())
        let out = try jsonBody(outcome)
        #expect(out["categoryId"] as? String == "77")
        #expect(out["siteId"] as? String == "9")
        let packages = out["packages"] as? [[String: String]]
        #expect(packages == [["packageId": "31", "version": "120.0"]])
        guard case .write(let object) = outcome else { return }
        #expect(object.warnings.count == 1) // the unknown package was dropped with a warning
    }

    @Test func appInstallersDisableWhenTheGroupIsMissing() throws {
        let json: [String: Any] = [
            "id": "2", "name": "Slack", "enabled": true,
            "titleAvailableInAis": true, "selectedVersion": "4.39",
            "smartGroupId": "17", "smartGroupName": "Missing Group",
            "categoryName": "Utilities", "siteName": "None",
        ]
        let out = try jsonBody(ProTransformer.transform(type: ObjectRegistry.type("appinstallers")!, json: json, context: context()))
        #expect(out["titleAvailableInAis"] == nil)
        #expect(out["enabled"] as? Bool == false)
        #expect(out["smartGroupId"] == nil)
        #expect(out["categoryId"] as? String == "77")
        #expect(out["siteId"] as? String == "-1")
    }

    @Test func appInstallersRemapTheScope() throws {
        let json: [String: Any] = ["id": "2", "name": "Slack", "enabled": true,
                                   "smartGroupId": "17", "smartGroupName": "All Laptops"]
        let out = try jsonBody(ProTransformer.transform(type: ObjectRegistry.type("appinstallers")!, json: json, context: context()))
        #expect(out["smartGroupId"] as? String == "12")
        #expect(out["enabled"] as? Bool == true)
    }
}
