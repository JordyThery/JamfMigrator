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
import JTKit

/// Which API family a type lives on, with its pinned resource path.
enum ObjectAPI: Hashable, Sendable {
    /// Jamf Pro API: /pro/v{version}/{resource}. JSON.
    case pro(version: Int, resource: String)
    /// Classic API: /proclassic/{resource}. JSON for lists, XML for details and writes.
    /// `idPath` is the path component before the id ("id" for everything except
    /// Jamf account users/groups, which use "userid"/"groupid").
    case classic(resource: String, idPath: String)
    /// Platform-only namespaces served by the gateway root (Blueprints,
    /// Compliance Benchmarks). JSON; no direct Jamf Pro equivalent.
    case platform(resource: String)

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
        case .platform(let resource): resource
        }
    }

    func detailPath(id: String) -> String {
        switch self {
        case .pro(let version, let resource): "pro/v\(version)/\(resource)/\(id)"
        case .classic(let resource, let idPath): "proclassic/\(resource)/\(idPath)/\(id)"
        case .platform(let resource): "\(resource)/\(id)"
        }
    }

    var createPath: String {
        switch self {
        case .pro, .platform: listPath
        case .classic(let resource, let idPath): "proclassic/\(resource)/\(idPath)/0"
        }
    }
}

/// How the list response is shaped.
enum ListShape: Sendable {
    /// Pro: {"totalCount": n, "results": [...]} with page/page-size paging.
    case proPaginated
    /// Pro: a bare JSON array of every object, unpaginated (patch title
    /// configurations, verified live 2026-10-22).
    case proArray
    /// Classic: {"<container>": [{id, name}, ...]}.
    case classicArray(container: String)
    /// Classic /accounts: {"accounts": {"users": [...], "groups": [...]}}.
    case classicAccounts(sub: String)
    /// A settings singleton: no list, no id. GET and PUT/PATCH the same path;
    /// it always exists on both tenants, so runs only ever update it.
    case singleton
}

/// What a type needs to be read and written: its Jamf Pro privileges, from
/// JTKit's table, and its Jamf Account capability behind the gateway (see
/// docs/PERMISSIONS.md). Each request names its privileges, so a refusal
/// (403) on a direct connection says which one is missing.
struct ObjectAccess: Sendable {
    /// The gateway capability, e.g. "policies".
    var capability: String
    var read: [JamfPro.Privilege] = []
    var create: [JamfPro.Privilege] = []
    var update: [JamfPro.Privilege] = []
    var delete: [JamfPro.Privilege] = []
    /// The Jamf Account permission reading the list needs, when it isn't
    /// the capability's read.
    var gatewayRead: String?

    /// The Jamf Account permission the list needs, e.g. "policies:read".
    var readPermission: String { gatewayRead ?? "\(capability):read" }

    /// The privileges a request with `method` needs.
    func privileges(for method: HTTPMethod) -> [JamfPro.Privilege] {
        switch method {
        case .get: read
        case .post: create
        case .put, .patch: update
        case .delete: delete
        }
    }

    /// An object with one privilege per action.
    static func crud(_ capability: String, read: JamfPro.Privilege, create: JamfPro.Privilege,
                     update: JamfPro.Privilege, delete: JamfPro.Privilege) -> ObjectAccess {
        ObjectAccess(capability: capability, read: [read], create: [create], update: [update], delete: [delete])
    }

    /// A settings singleton: only read and updated.
    static func settings(_ capability: String, read: JamfPro.Privilege, update: JamfPro.Privilege) -> ObjectAccess {
        ObjectAccess(capability: capability, read: [read], update: [update])
    }

    /// A Platform namespace with no Jamf Pro privileges (Blueprints, Compliance Benchmarks).
    static func gatewayOnly(_ capability: String) -> ObjectAccess {
        ObjectAccess(capability: capability)
    }
}

struct ObjectType: Identifiable, Sendable {
    let key: String
    let displayName: String
    /// Migration step (1-13). Types run in
    /// registry order; deletes run in exact reverse registry order.
    let step: Int
    let api: ObjectAPI
    let listShape: ListShape
    let access: ObjectAccess
    /// Field holding the object's unique name in list entries ("name" almost
    /// everywhere, "displayName" for patch titles).
    var nameKey: String = "name"
    var updateMethod: HTTPMethod = .put
    /// Registry keys this type references; they must migrate first.
    var dependencies: [String] = []
    /// Write-only secrets the API never returns; surfaced as warnings.
    var secretFields: [String] = []
    /// Platform-only namespaces (Blueprints, Compliance Benchmarks) have no
    /// direct Jamf Pro equivalent and are Blocked on direct connections.
    var requiresGateway = false
    /// Its writes carry values no log may hold (licence serial numbers):
    /// they are recorded without contents, and the values are blanked out
    /// of a failure's reason.
    /// The XML tags holding them, without their number: "serial_number_"
    /// for `<serial_number_1>`, `<serial_number_2>`.
    var secretTagPrefix: String?
    var id: String { key }

    /// The secret values in a payload of this type, longest first.
    func secretValues(in text: String) -> [String] {
        guard let secretTagPrefix else { return [] }
        let tag = NSRegularExpression.escapedPattern(for: secretTagPrefix)
        guard let regex = try? Regex("(?s)<\(tag)\\d*>(.*?)</\(tag)\\d*>") else { return [] }
        let values = text.matches(of: regex)
            .compactMap { $0.output.count > 1 ? $0.output[1].substring.map(String.init) : nil }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(Set(values)).sorted { $0.count > $1.count }
    }

    /// Where updates go: singletons PUT/PATCH their one path.
    func updatePath(destId: String) -> String {
        if case .singleton = listShape {
            return api.listPath
        }
        return api.detailPath(id: destId)
    }
}

enum ObjectRegistry {

    /// All migratable types, in migration order.
    static let types: [ObjectType] = [
        // step 1
        ObjectType(key: "sites", displayName: "Sites", step: 1,
                   api: .classic("sites"), listShape: .classicArray(container: "sites"),
                   access: .crud("sites", read: .readSites, create: .createSites, update: .updateSites, delete: .deleteSites)),

        // step 2
        ObjectType(key: "categories", displayName: "Categories", step: 2,
                   api: .pro(version: 1, resource: "categories"), listShape: .proPaginated,
                   access: .crud("categories", read: .readCategories, create: .createCategories, update: .updateCategories, delete: .deleteCategories)),
        ObjectType(key: "buildings", displayName: "Buildings", step: 2,
                   api: .pro(version: 1, resource: "buildings"), listShape: .proPaginated,
                   access: .crud("buildings", read: .readBuildings, create: .createBuildings, update: .updateBuildings, delete: .deleteBuildings)),
        ObjectType(key: "departments", displayName: "Departments", step: 2,
                   api: .pro(version: 1, resource: "departments"), listShape: .proPaginated,
                   access: .crud("departments", read: .readDepartments, create: .createDepartments, update: .updateDepartments, delete: .deleteDepartments)),
        ObjectType(key: "networksegments", displayName: "Network segments", step: 2,
                   api: .classic("networksegments"), listShape: .classicArray(container: "network_segments"),
                   access: .crud("network-segments", read: .readNetworkSegments, create: .createNetworkSegments, update: .updateNetworkSegments, delete: .deleteNetworkSegments)),

        // step 3
        ObjectType(key: "computerextensionattributes", displayName: "Computer extension attributes", step: 3,
                   api: .pro(version: 1, resource: "computer-extension-attributes"), listShape: .proPaginated,
                   access: .crud("extension-attributes", read: .readComputerExtensionAttributes, create: .createComputerExtensionAttributes, update: .updateComputerExtensionAttributes, delete: .deleteComputerExtensionAttributes)),
        ObjectType(key: "mobiledeviceextensionattributes", displayName: "Mobile device extension attributes", step: 3,
                   api: .pro(version: 1, resource: "mobile-device-extension-attributes"), listShape: .proPaginated,
                   access: .crud("extension-attributes", read: .readMobileDeviceExtensionAttributes, create: .createMobileDeviceExtensionAttributes, update: .updateMobileDeviceExtensionAttributes, delete: .deleteMobileDeviceExtensionAttributes)),
        ObjectType(key: "userextensionattributes", displayName: "User extension attributes", step: 3,
                   api: .classic("userextensionattributes"), listShape: .classicArray(container: "user_extension_attributes"),
                   access: .crud("user-extension-attributes", read: .readUserExtensionAttributes, create: .createUserExtensionAttributes, update: .updateUserExtensionAttributes, delete: .deleteUserExtensionAttributes)),

        // step 4
        ObjectType(key: "scripts", displayName: "Scripts", step: 4,
                   api: .pro(version: 1, resource: "scripts"), listShape: .proPaginated,
                   access: .crud("scripts", read: .readScripts, create: .createScripts, update: .updateScripts, delete: .deleteScripts),
                   dependencies: ["categories"]),
        ObjectType(key: "packages", displayName: "Packages", step: 4,
                   api: .pro(version: 1, resource: "packages"), listShape: .proPaginated,
                   access: .crud("packages", read: .readPackages, create: .createPackages, update: .updatePackages, delete: .deletePackages),
                   nameKey: "packageName",
                   dependencies: ["categories"]),
        ObjectType(key: "distributionpoints", displayName: "Distribution points", step: 4,
                   api: .pro(version: 1, resource: "distribution-points"), listShape: .proPaginated,
                   access: ObjectAccess(capability: "distribution-points", read: [.readDistributionPoints], create: [.createDistributionPoints],
                                        update: [.readDistributionPoints, .updateDistributionPoints], delete: [.deleteDistributionPoints]),
                   secretFields: ["read/write password", "read-only password"]),

        // step 5
        ObjectType(key: "ldapservers", displayName: "LDAP servers", step: 5,
                   api: .classic("ldapservers"), listShape: .classicArray(container: "ldap_servers"),
                   access: .crud("ldap-servers", read: .readLDAPServers, create: .createLDAPServers, update: .updateLDAPServers, delete: .deleteLDAPServers),
                   secretFields: ["bind password"]),
        ObjectType(key: "jamfusers", displayName: "Jamf user accounts", step: 5,
                   api: .pro(version: 1, resource: "accounts"), listShape: .proPaginated,
                   access: .crud("accounts", read: .readAccounts, create: .createAccounts, update: .updateAccounts, delete: .deleteAccounts),
                   nameKey: "username",
                   dependencies: ["sites"], secretFields: ["password"]),
        ObjectType(key: "jamfgroups", displayName: "Jamf group accounts", step: 5,
                   api: .classic(resource: "accounts", idPath: "groupid"),
                   listShape: .classicAccounts(sub: "groups"),
                   access: .crud("accounts", read: .readAccounts, create: .createAccounts, update: .updateAccounts, delete: .deleteAccounts),
                   dependencies: ["sites", "ldapservers"]),
        ObjectType(key: "users", displayName: "Users", step: 5,
                   api: .classic("users"), listShape: .classicArray(container: "users"),
                   access: .crud("users", read: .readUser, create: .createUser, update: .updateUser, delete: .deleteUser),
                   dependencies: ["sites"]),
        ObjectType(key: "usergroups", displayName: "User groups", step: 5,
                   api: .classic("usergroups"), listShape: .classicArray(container: "user_groups"),
                   access: ObjectAccess(capability: "user-groups", read: [.readSmartUserGroups, .readStaticUserGroups],
                                        create: [.createSmartUserGroups, .createStaticUserGroups],
                                        update: [.updateSmartUserGroups, .updateStaticUserGroups],
                                        delete: [.deleteSmartUserGroups, .deleteStaticUserGroups]),
                   dependencies: ["users", "sites"]),
        ObjectType(key: "directorybindings", displayName: "Directory bindings", step: 5,
                   api: .classic("directorybindings"), listShape: .classicArray(container: "directory_bindings"),
                   access: .crud("directory-bindings", read: .readDirectoryBindings, create: .createDirectoryBindings, update: .updateDirectoryBindings, delete: .deleteDirectoryBindings),
                   secretFields: ["bind password"]),
        ObjectType(key: "softwareupdateservers", displayName: "Software update servers", step: 5,
                   api: .classic("softwareupdateservers"), listShape: .classicArray(container: "software_update_servers"),
                   access: .crud("software-update-servers", read: .readSoftwareUpdateServers, create: .createSoftwareUpdateServers, update: .updateSoftwareUpdateServers, delete: .deleteSoftwareUpdateServers)),

        // step 6 (gateway serves computer groups at v3, mobile at v2)
        ObjectType(key: "smartcomputergroups", displayName: "Smart computer groups", step: 6,
                   api: .pro(version: 3, resource: "computer-groups/smart-groups"), listShape: .proPaginated,
                   access: .crud("device-groups", read: .readSmartComputerGroups, create: .createSmartComputerGroups, update: .updateSmartComputerGroups, delete: .deleteSmartComputerGroups),
                   dependencies: ["sites", "computerextensionattributes"]),
        ObjectType(key: "staticcomputergroups", displayName: "Static computer groups", step: 6,
                   api: .pro(version: 3, resource: "computer-groups/static-groups"), listShape: .proPaginated,
                   access: .crud("device-groups", read: .readStaticComputerGroups, create: .createStaticComputerGroups, update: .updateStaticComputerGroups, delete: .deleteStaticComputerGroups),
                   dependencies: ["sites"]),
        ObjectType(key: "smartmobiledevicegroups", displayName: "Smart mobile device groups", step: 6,
                   api: .pro(version: 2, resource: "mobile-device-groups/smart-groups"), listShape: .proPaginated,
                   access: .crud("device-groups", read: .readSmartMobileDeviceGroups, create: .createSmartMobileDeviceGroups, update: .updateSmartMobileDeviceGroups, delete: .deleteSmartMobileDeviceGroups),
                   dependencies: ["sites", "mobiledeviceextensionattributes"]),
        ObjectType(key: "staticmobiledevicegroups", displayName: "Static mobile device groups", step: 6,
                   api: .pro(version: 2, resource: "mobile-device-groups/static-groups"), listShape: .proPaginated,
                   access: .crud("device-groups", read: .readStaticMobileDeviceGroups, create: .createStaticMobileDeviceGroups, update: .updateStaticMobileDeviceGroups, delete: .deleteStaticMobileDeviceGroups),
                   updateMethod: .patch,
                   dependencies: ["sites"]),
        ObjectType(key: "advancedcomputersearches", displayName: "Advanced computer searches", step: 6,
                   api: .classic("advancedcomputersearches"), listShape: .classicArray(container: "advanced_computer_searches"),
                   access: .crud("advanced-device-searches", read: .readAdvancedComputerSearches, create: .createAdvancedComputerSearches, update: .updateAdvancedComputerSearches, delete: .deleteAdvancedComputerSearches),
                   dependencies: ["sites", "computerextensionattributes"]),
        ObjectType(key: "advancedmobiledevicesearches", displayName: "Advanced mobile device searches", step: 6,
                   api: .pro(version: 1, resource: "advanced-mobile-device-searches"), listShape: .proPaginated,
                   access: .crud("advanced-device-searches", read: .readAdvancedMobileDeviceSearches, create: .createAdvancedMobileDeviceSearches, update: .updateAdvancedMobileDeviceSearches, delete: .deleteAdvancedMobileDeviceSearches),
                   dependencies: ["sites"]),
        ObjectType(key: "advancedusersearches", displayName: "Advanced user searches", step: 6,
                   api: .classic("advancedusersearches"), listShape: .classicArray(container: "advanced_user_searches"),
                   access: .crud("advanced-user-searches", read: .readAdvancedUserSearches, create: .createAdvancedUserSearches, update: .updateAdvancedUserSearches, delete: .deleteAdvancedUserSearches),
                   dependencies: ["sites"]),

        // step 7
        ObjectType(key: "osxconfigurationprofiles", displayName: "macOS configuration profiles", step: 7,
                   api: .classic("osxconfigurationprofiles"), listShape: .classicArray(container: "os_x_configuration_profiles"),
                   access: .crud("configuration-profiles", read: .readMacOSConfigurationProfiles, create: .createMacOSConfigurationProfiles, update: .updateMacOSConfigurationProfiles, delete: .deleteMacOSConfigurationProfiles),
                   dependencies: ["categories", "sites", "smartcomputergroups", "staticcomputergroups"]),
        ObjectType(key: "mobiledeviceconfigurationprofiles", displayName: "Mobile device configuration profiles", step: 7,
                   api: .classic("mobiledeviceconfigurationprofiles"), listShape: .classicArray(container: "configuration_profiles"),
                   access: .crud("configuration-profiles", read: .readIOSConfigurationProfiles, create: .createIOSConfigurationProfiles, update: .updateIOSConfigurationProfiles, delete: .deleteIOSConfigurationProfiles),
                   dependencies: ["categories", "sites", "smartmobiledevicegroups", "staticmobiledevicegroups"]),
        ObjectType(key: "macapplications", displayName: "Mac applications", step: 7,
                   api: .classic("macapplications"), listShape: .classicArray(container: "mac_applications"),
                   access: .crud("applications", read: .readMacApplications, create: .createMacApplications, update: .updateMacApplications, delete: .deleteMacApplications),
                   dependencies: ["categories", "sites", "smartcomputergroups", "staticcomputergroups"]),
        ObjectType(key: "mobiledeviceapplications", displayName: "Mobile device applications", step: 7,
                   api: .classic("mobiledeviceapplications"), listShape: .classicArray(container: "mobile_device_applications"),
                   access: .crud("applications", read: .readMobileDeviceApplications, create: .createMobileDeviceApplications, update: .updateMobileDeviceApplications, delete: .deleteMobileDeviceApplications),
                   dependencies: ["categories", "sites", "smartmobiledevicegroups", "staticmobiledevicegroups"]),
        ObjectType(key: "ebooks", displayName: "eBooks", step: 7,
                   api: .classic("ebooks"), listShape: .classicArray(container: "ebooks"),
                   access: .crud("ebooks", read: .readEBooks, create: .createEBooks, update: .updateEBooks, delete: .deleteEBooks),
                   dependencies: ["categories", "sites"]),
        ObjectType(key: "classes", displayName: "Classes", step: 7,
                   api: .classic("classes"), listShape: .classicArray(container: "classes"),
                   access: .crud("classes", read: .readClasses, create: .createClasses, update: .updateClasses, delete: .deleteClasses),
                   dependencies: ["sites", "usergroups", "staticmobiledevicegroups"]),
        ObjectType(key: "restrictedsoftware", displayName: "Restricted software", step: 7,
                   api: .classic("restrictedsoftware"), listShape: .classicArray(container: "restricted_software"),
                   access: .crud("restricted-software", read: .readRestrictedSoftware, create: .createRestrictedSoftware, update: .updateRestrictedSoftware, delete: .deleteRestrictedSoftware),
                   dependencies: ["sites", "smartcomputergroups", "staticcomputergroups"]),
        ObjectType(key: "licensedsoftware", displayName: "Licensed software", step: 7,
                   api: .classic("licensedsoftware"), listShape: .classicArray(container: "licensed_software"),
                   access: .crud("licensed-software", read: .readLicensedSoftware, create: .createLicensedSoftware, update: .updateLicensedSoftware, delete: .deleteLicensedSoftware),
                   dependencies: ["sites"],
                   secretTagPrefix: "serial_number_"),
        ObjectType(key: "printers", displayName: "Printers", step: 7,
                   api: .classic("printers"), listShape: .classicArray(container: "printers"),
                   access: .crud("printers", read: .readPrinters, create: .createPrinters, update: .updatePrinters, delete: .deletePrinters),
                   dependencies: ["categories"]),
        ObjectType(key: "dockitems", displayName: "Dock items", step: 7,
                   api: .classic("dockitems"), listShape: .classicArray(container: "dock_items"),
                   access: .crud("dock-items", read: .readDockItems, create: .createDockItems, update: .updateDockItems, delete: .deleteDockItems)),

        // step 8
        ObjectType(key: "policies", displayName: "Policies", step: 8,
                   api: .classic("policies"), listShape: .classicArray(container: "policies"),
                   access: .crud("policies", read: .readPolicies, create: .createPolicies, update: .updatePolicies, delete: .deletePolicies),
                   dependencies: ["categories", "sites", "smartcomputergroups", "staticcomputergroups",
                                  "packages", "scripts", "printers", "dockitems", "networksegments", "distributionpoints"]),
        ObjectType(key: "patchsoftwaretitles", displayName: "Patch management titles", step: 8,
                   api: .pro(version: 3, resource: "patch-software-title-configurations"), listShape: .proArray,
                   access: .crud("patch-management-software-titles", read: .readPatchManagementSoftwareTitles, create: .createPatchManagementSoftwareTitles, update: .updatePatchManagementSoftwareTitles, delete: .deletePatchManagementSoftwareTitles),
                   nameKey: "displayName", updateMethod: .patch,
                   dependencies: ["categories", "sites", "packages"]),
        ObjectType(key: "patchpolicies", displayName: "Patch policies", step: 8,
                   api: .classic("patchpolicies"), listShape: .classicArray(container: "patch_policies"),
                   access: .crud("patch-policies", read: .readPatchPolicies, create: .createPatchPolicies, update: .updatePatchPolicies, delete: .deletePatchPolicies),
                   dependencies: ["patchsoftwaretitles", "smartcomputergroups", "staticcomputergroups"]),
        ObjectType(key: "appinstallers", displayName: "App Installers", step: 8,
                   api: .pro(version: 1, resource: "app-installers/deployments"), listShape: .proPaginated,
                   access: .crud("applications", read: .readMacApplications, create: .createMacApplications, update: .updateMacApplications, delete: .deleteMacApplications),
                   dependencies: ["categories", "sites", "smartcomputergroups"]),

        // step 9
        ObjectType(key: "enrollmentcustomizations", displayName: "Enrollment customizations", step: 9,
                   api: .pro(version: 2, resource: "enrollment-customizations"), listShape: .proPaginated,
                   access: ObjectAccess(capability: "enrollment-customization", read: [.readEnrollmentCustomizations],
                                        create: [.createEnrollmentCustomizations], update: [.updateEnrollmentCustomizations],
                                        delete: [.deleteEnrollmentCustomizations, .readEnrollmentCustomizations]),
                   nameKey: "displayName",
                   dependencies: ["sites"]),

        // step 10
        ObjectType(key: "computerprestages", displayName: "Computer PreStages", step: 10,
                   api: .pro(version: 3, resource: "computer-prestages"), listShape: .proPaginated,
                   access: .crud("prestage-enrollments", read: .readComputerPreStageEnrollments, create: .createComputerPreStageEnrollments, update: .updateComputerPreStageEnrollments, delete: .deleteComputerPreStageEnrollments),
                   nameKey: "displayName",
                   dependencies: ["sites", "buildings", "departments", "packages",
                                  "osxconfigurationprofiles", "enrollmentcustomizations", "distributionpoints"],
                   secretFields: ["admin password", "recovery lock password"]),
        ObjectType(key: "mobiledeviceprestages", displayName: "Mobile device PreStages", step: 10,
                   api: .pro(version: 3, resource: "mobile-device-prestages"), listShape: .proPaginated,
                   access: .crud("prestage-enrollments", read: .readMobileDevicePreStageEnrollments, create: .createMobileDevicePreStageEnrollments, update: .updateMobileDevicePreStageEnrollments, delete: .deleteMobileDevicePreStageEnrollments),
                   nameKey: "displayName",
                   dependencies: ["sites", "mobiledeviceconfigurationprofiles", "enrollmentcustomizations"]),

        // step 11 (platform namespace: gateway only; pattern is
        // /{namespace}/v{n}/{resource} — the gateway answers a wrong path with
        // 403 BAD_PERMISSIONS, not 404; verified live 2026-10-04)
        ObjectType(key: "blueprints", displayName: "Blueprints", step: 11,
                   api: .platform(resource: "blueprints/v1/blueprints"), listShape: .proPaginated,
                   access: .gatewayOnly("blueprints"),
                   updateMethod: .patch,
                   requiresGateway: true),

        // step 12 (platform namespace: gateway only; no update endpoint → Replace;
        // the list nests under "benchmarks", not "results")
        ObjectType(key: "compliancebenchmarks", displayName: "Compliance Benchmarks", step: 12,
                   api: .platform(resource: "compliance-benchmarks/v1/benchmarks"),
                   listShape: .classicArray(container: "benchmarks"),
                   access: .gatewayOnly("compliance-benchmarks"),
                   nameKey: "title",
                   requiresGateway: true),

        // step 13: tenant settings and webhooks
        ObjectType(key: "webhooks", displayName: "Webhooks", step: 13,
                   api: .classic("webhooks"), listShape: .classicArray(container: "webhooks"),
                   access: .crud("webhooks", read: .readWebhooks, create: .createWebhooks, update: .updateWebhooks, delete: .deleteWebhooks),
                   dependencies: ["smartcomputergroups", "staticcomputergroups"],
                   secretFields: ["webhook password"]),
        ObjectType(key: "checkin", displayName: "Check-in settings", step: 13,
                   api: .pro(version: 3, resource: "check-in"), listShape: .singleton,
                   access: .settings("computer-check-in", read: .readComputerCheckIn, update: .updateComputerCheckIn)),
        ObjectType(key: "inventorycollection", displayName: "Inventory collection settings", step: 13,
                   api: .pro(version: 2, resource: "computer-inventory-collection-settings"), listShape: .singleton,
                   access: .settings("computer-inventory-collection-settings", read: .readComputerInventoryCollectionSettings,
                                     update: .updateComputerInventoryCollectionSettings),
                   updateMethod: .patch),
        ObjectType(key: "smtpserver", displayName: "SMTP server", step: 13,
                   api: .pro(version: 2, resource: "smtp-server"), listShape: .singleton,
                   access: .settings("smtp-server", read: .readSMTPServer, update: .updateSMTPServer),
                   secretFields: ["SMTP password"]),
        ObjectType(key: "selfservicesettings", displayName: "Self Service settings", step: 13,
                   api: .pro(version: 1, resource: "self-service/settings"), listShape: .singleton,
                   access: .settings("self-service", read: .readSelfService, update: .updateSelfService)),
        ObjectType(key: "reenrollment", displayName: "Re-enrollment settings", step: 13,
                   api: .pro(version: 1, resource: "reenrollment"), listShape: .singleton,
                   access: .settings("re-enrollment", read: .readReEnrollment, update: .updateReEnrollment)),
        ObjectType(key: "lapssettings", displayName: "LAPS settings", step: 13,
                   api: .pro(version: 2, resource: "local-admin-password/settings"), listShape: .singleton,
                   access: ObjectAccess(capability: "local-admin-passwords",
                                        // Jamf's API asks for the update privilege and permission also to read them
                                        read: [.updateLocalAdminPasswordSettings, .readUserInitiatedEnrollment],
                                        update: [.updateLocalAdminPasswordSettings],
                                        gatewayRead: "local-admin-passwords:update")),
        ObjectType(key: "onboarding", displayName: "Onboarding", step: 13,
                   api: .pro(version: 1, resource: "onboarding"), listShape: .singleton,
                   access: .settings("onboarding", read: .readOnboardingConfiguration, update: .updateOnboardingConfiguration)),
        ObjectType(key: "sso", displayName: "Single sign-on", step: 13,
                   api: .pro(version: 3, resource: "sso"), listShape: .singleton,
                   access: .settings("sso-settings", read: .readSSOSettings, update: .updateSSOSettings),
                   secretFields: ["SSO secrets and certificates"]),
    ]

    static func type(_ key: String) -> ObjectType? {
        types.first { $0.key == key }
    }

    /// Deletion runs in the exact reverse of migration order.
    static var deletionOrder: [ObjectType] { types.reversed() }
}
