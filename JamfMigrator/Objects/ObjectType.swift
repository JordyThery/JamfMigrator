//
//  ObjectType.swift
//  JamfMigrator
//
//  The registry of migratable object types. Every type is pinned to the
//  newest endpoint version the gateway serves (older versions answer 403),
//  and to the Pro API wherever it has full CRUD. A unit test checks each pin
//  against the vendored jamf-cli gateway spec.
//

import Foundation

/// Which API family a type lives on, with its pinned resource path.
enum ObjectAPI: Hashable, Sendable {
    /// Jamf Pro API: /pro/v{version}/{resource}. JSON.
    case pro(version: Int, resource: String)
    /// Classic API: /proclassic/{resource}. JSON for lists, XML for details and writes.
    /// `idPath` is the path component before the id ("id" for everything except
    /// Jamf account users/groups, which use "userid"/"groupid").
    case classic(resource: String, idPath: String)

    static func classic(_ resource: String) -> ObjectAPI {
        .classic(resource: resource, idPath: "id")
    }

    var isClassic: Bool {
        if case .classic = self { return true }
        return false
    }

    /// The list endpoint. Classic lists are requested with Accept: application/json.
    var listPath: String {
        switch self {
        case .pro(let version, let resource): "pro/v\(version)/\(resource)"
        case .classic(let resource, _): "proclassic/\(resource)"
        }
    }

    func detailPath(id: String) -> String {
        switch self {
        case .pro(let version, let resource): "pro/v\(version)/\(resource)/\(id)"
        case .classic(let resource, let idPath): "proclassic/\(resource)/\(idPath)/\(id)"
        }
    }

    var createPath: String {
        switch self {
        case .pro: listPath
        case .classic(let resource, let idPath): "proclassic/\(resource)/\(idPath)/0"
        }
    }
}

/// How the list response is shaped.
enum ListShape: Sendable {
    /// Pro: {"totalCount": n, "results": [...]} with page/page-size paging.
    case proPaginated
    /// Pro: a bare JSON array (e.g. /pro/v1/sites).
    case proArray
    /// Classic: {"<container>": [{id, name}, ...]}.
    case classicArray(container: String)
    /// Classic /accounts: {"accounts": {"users": [...], "groups": [...]}}.
    case classicAccounts(sub: String)
}

struct ObjectType: Identifiable, Sendable {
    let key: String
    let displayName: String
    /// Migration step (1...8 for now; 9+ arrive in Phase 6). Types run in
    /// registry order; deletes run in exact reverse registry order.
    let step: Int
    let api: ObjectAPI
    let listShape: ListShape
    /// Field holding the object's unique name in list entries ("name" almost
    /// everywhere, "displayName" for patch titles).
    var nameKey: String = "name"
    var updateMethod: HTTPMethod = .put
    /// Registry keys this type references; they must migrate first.
    var dependencies: [String] = []
    /// Write-only secrets the API never returns; surfaced as warnings.
    var secretFields: [String] = []
    var id: String { key }
}

enum ObjectRegistry {

    /// Steps 1-8, in migration order.
    static let types: [ObjectType] = [
        // step 1
        ObjectType(key: "sites", displayName: "Sites", step: 1,
                   api: .classic("sites"), listShape: .classicArray(container: "sites")),

        // step 2
        ObjectType(key: "categories", displayName: "Categories", step: 2,
                   api: .pro(version: 1, resource: "categories"), listShape: .proPaginated),
        ObjectType(key: "buildings", displayName: "Buildings", step: 2,
                   api: .pro(version: 1, resource: "buildings"), listShape: .proPaginated),
        ObjectType(key: "departments", displayName: "Departments", step: 2,
                   api: .pro(version: 1, resource: "departments"), listShape: .proPaginated),
        ObjectType(key: "networksegments", displayName: "Network segments", step: 2,
                   api: .classic("networksegments"), listShape: .classicArray(container: "network_segments")),

        // step 3
        ObjectType(key: "computerextensionattributes", displayName: "Computer extension attributes", step: 3,
                   api: .pro(version: 1, resource: "computer-extension-attributes"), listShape: .proPaginated),
        ObjectType(key: "mobiledeviceextensionattributes", displayName: "Mobile device extension attributes", step: 3,
                   api: .pro(version: 1, resource: "mobile-device-extension-attributes"), listShape: .proPaginated),
        ObjectType(key: "userextensionattributes", displayName: "User extension attributes", step: 3,
                   api: .classic("userextensionattributes"), listShape: .classicArray(container: "user_extension_attributes")),

        // step 4
        ObjectType(key: "scripts", displayName: "Scripts", step: 4,
                   api: .pro(version: 1, resource: "scripts"), listShape: .proPaginated,
                   dependencies: ["categories"]),
        ObjectType(key: "packages", displayName: "Packages", step: 4,
                   api: .pro(version: 1, resource: "packages"), listShape: .proPaginated,
                   dependencies: ["categories"]),
        ObjectType(key: "distributionpoints", displayName: "Distribution points", step: 4,
                   api: .pro(version: 1, resource: "distribution-points"), listShape: .proPaginated,
                   secretFields: ["read/write password", "read-only password"]),

        // step 5
        ObjectType(key: "ldapservers", displayName: "LDAP servers", step: 5,
                   api: .classic("ldapservers"), listShape: .classicArray(container: "ldap_servers"),
                   secretFields: ["bind password"]),
        ObjectType(key: "jamfusers", displayName: "Jamf user accounts", step: 5,
                   api: .pro(version: 1, resource: "accounts"), listShape: .proPaginated,
                   dependencies: ["sites"], secretFields: ["password"]),
        ObjectType(key: "jamfgroups", displayName: "Jamf group accounts", step: 5,
                   api: .classic(resource: "accounts", idPath: "groupid"),
                   listShape: .classicAccounts(sub: "groups"),
                   dependencies: ["sites", "ldapservers"]),
        ObjectType(key: "users", displayName: "Users", step: 5,
                   api: .classic("users"), listShape: .classicArray(container: "users"),
                   dependencies: ["sites"]),
        ObjectType(key: "usergroups", displayName: "User groups", step: 5,
                   api: .classic("usergroups"), listShape: .classicArray(container: "user_groups"),
                   dependencies: ["users", "sites"]),
        ObjectType(key: "directorybindings", displayName: "Directory bindings", step: 5,
                   api: .classic("directorybindings"), listShape: .classicArray(container: "directory_bindings"),
                   secretFields: ["bind password"]),
        ObjectType(key: "softwareupdateservers", displayName: "Software update servers", step: 5,
                   api: .classic("softwareupdateservers"), listShape: .classicArray(container: "software_update_servers")),

        // step 6 (gateway serves computer groups at v3, mobile at v2)
        ObjectType(key: "smartcomputergroups", displayName: "Smart computer groups", step: 6,
                   api: .pro(version: 3, resource: "computer-groups/smart-groups"), listShape: .proPaginated,
                   dependencies: ["sites", "computerextensionattributes"]),
        ObjectType(key: "staticcomputergroups", displayName: "Static computer groups", step: 6,
                   api: .pro(version: 3, resource: "computer-groups/static-groups"), listShape: .proPaginated,
                   dependencies: ["sites"]),
        ObjectType(key: "smartmobiledevicegroups", displayName: "Smart mobile device groups", step: 6,
                   api: .pro(version: 2, resource: "mobile-device-groups/smart-groups"), listShape: .proPaginated,
                   dependencies: ["sites", "mobiledeviceextensionattributes"]),
        ObjectType(key: "staticmobiledevicegroups", displayName: "Static mobile device groups", step: 6,
                   api: .pro(version: 2, resource: "mobile-device-groups/static-groups"), listShape: .proPaginated,
                   updateMethod: .patch,
                   dependencies: ["sites"]),
        ObjectType(key: "advancedcomputersearches", displayName: "Advanced computer searches", step: 6,
                   api: .classic("advancedcomputersearches"), listShape: .classicArray(container: "advanced_computer_searches"),
                   dependencies: ["sites", "computerextensionattributes"]),
        ObjectType(key: "advancedmobiledevicesearches", displayName: "Advanced mobile device searches", step: 6,
                   api: .pro(version: 1, resource: "advanced-mobile-device-searches"), listShape: .proPaginated,
                   dependencies: ["sites"]),
        ObjectType(key: "advancedusersearches", displayName: "Advanced user searches", step: 6,
                   api: .classic("advancedusersearches"), listShape: .classicArray(container: "advanced_user_searches"),
                   dependencies: ["sites"]),

        // step 7
        ObjectType(key: "osxconfigurationprofiles", displayName: "macOS configuration profiles", step: 7,
                   api: .classic("osxconfigurationprofiles"), listShape: .classicArray(container: "os_x_configuration_profiles"),
                   dependencies: ["categories", "sites", "smartcomputergroups", "staticcomputergroups"]),
        ObjectType(key: "mobiledeviceconfigurationprofiles", displayName: "Mobile device configuration profiles", step: 7,
                   api: .classic("mobiledeviceconfigurationprofiles"), listShape: .classicArray(container: "configuration_profiles"),
                   dependencies: ["categories", "sites", "smartmobiledevicegroups", "staticmobiledevicegroups"]),
        ObjectType(key: "macapplications", displayName: "Mac applications", step: 7,
                   api: .classic("macapplications"), listShape: .classicArray(container: "mac_applications"),
                   dependencies: ["categories", "sites", "smartcomputergroups", "staticcomputergroups"]),
        ObjectType(key: "mobiledeviceapplications", displayName: "Mobile device applications", step: 7,
                   api: .classic("mobiledeviceapplications"), listShape: .classicArray(container: "mobile_device_applications"),
                   dependencies: ["categories", "sites", "smartmobiledevicegroups", "staticmobiledevicegroups"]),
        ObjectType(key: "ebooks", displayName: "eBooks", step: 7,
                   api: .classic("ebooks"), listShape: .classicArray(container: "ebooks"),
                   dependencies: ["categories", "sites"]),
        ObjectType(key: "classes", displayName: "Classes", step: 7,
                   api: .classic("classes"), listShape: .classicArray(container: "classes"),
                   dependencies: ["sites", "usergroups", "staticmobiledevicegroups"]),
        ObjectType(key: "restrictedsoftware", displayName: "Restricted software", step: 7,
                   api: .classic("restrictedsoftware"), listShape: .classicArray(container: "restricted_software"),
                   dependencies: ["sites", "smartcomputergroups", "staticcomputergroups"]),
        ObjectType(key: "printers", displayName: "Printers", step: 7,
                   api: .classic("printers"), listShape: .classicArray(container: "printers"),
                   dependencies: ["categories"]),
        ObjectType(key: "dockitems", displayName: "Dock items", step: 7,
                   api: .classic("dockitems"), listShape: .classicArray(container: "dock_items")),

        // step 8
        ObjectType(key: "policies", displayName: "Policies", step: 8,
                   api: .classic("policies"), listShape: .classicArray(container: "policies"),
                   dependencies: ["categories", "sites", "smartcomputergroups", "staticcomputergroups",
                                  "packages", "scripts", "printers", "dockitems", "networksegments", "distributionpoints"]),
        ObjectType(key: "patchsoftwaretitles", displayName: "Patch management titles", step: 8,
                   api: .pro(version: 3, resource: "patch-software-title-configurations"), listShape: .proPaginated,
                   nameKey: "displayName", updateMethod: .patch,
                   dependencies: ["categories", "sites", "packages"]),
        ObjectType(key: "patchpolicies", displayName: "Patch policies", step: 8,
                   api: .classic("patchpolicies"), listShape: .classicArray(container: "patch_policies"),
                   dependencies: ["patchsoftwaretitles", "smartcomputergroups", "staticcomputergroups"]),
        ObjectType(key: "appinstallers", displayName: "App Installers", step: 8,
                   api: .pro(version: 1, resource: "app-installers/deployments"), listShape: .proPaginated,
                   dependencies: ["categories", "sites", "smartcomputergroups"]),
    ]

    static func type(_ key: String) -> ObjectType? {
        types.first { $0.key == key }
    }

    /// Deletion runs in the exact reverse of migration order.
    static var deletionOrder: [ObjectType] { types.reversed() }
}
