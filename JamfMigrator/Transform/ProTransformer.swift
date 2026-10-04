//
//  ProTransformer.swift
//  JamfMigrator
//
//  Per-type rewriting of Jamf Pro API JSON payloads before they are written
//  to the destination.
//

import Foundation

enum ProTransformer {

    /// Rewrites a source object's Pro JSON for the destination.
    static func transform(type: ObjectType, json: [String: Any], context: TransformContext) -> TransformOutcome {
        var out = json
        var warnings = [String]()

        out["id"] = nil
        // drop JSON nulls so they don't overwrite destination defaults
        for (key, value) in out where value is NSNull {
            out[key] = nil
        }

        // settings singletons copy as-is; their secrets never leave the source
        if case .singleton = type.listShape {
            for secret in type.secretFields {
                warnings.append("The \(secret) is not returned by the API and must be re-entered on the destination.")
            }
            if type.key == "onboarding" {
                warnings.append("Onboarding items reference policies and profiles by id and may need to be reselected on the destination.")
            }
            do {
                let body = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
                return .write(TransformedObject(body: body, contentType: "application/json", warnings: warnings))
            } catch {
                return .blocked(reason: "The payload could not be encoded: \(error.localizedDescription)")
            }
        }

        switch type.key {
        case "categories", "buildings", "departments", "mobiledeviceextensionattributes":
            break

        case "computerextensionattributes":
            if out["description"] as? String == "Extension Attribute provided by JAMF Nation patch service" {
                return .blocked(reason: "Patch extension attributes are not migrated")
            }

        case "scripts":
            remapCategory(&out, context: context, warnings: &warnings)

        case "packages":
            remapCategory(&out, context: context, warnings: &warnings)
            // the destination computes its own hashes; records point at files
            // that must already exist on its distribution points
            for field in ["md5", "sha256", "hashType", "hashValue", "size", "cloudTransferStatus"] {
                out[field] = nil
            }

        case "distributionpoints":
            // the API never returns these; field names per the v1 schema
            // (not exercised live — the test tenants have no file shares)
            if let readWrite = context.secrets["fsrw"] { out["readWritePassword"] = readWrite }
            if let readOnly = context.secrets["fsro"] { out["readOnlyPassword"] = readOnly }
            if context.secrets["fsrw"] == nil || context.secrets["fsro"] == nil {
                warnings.append("File-share passwords are not returned by the API; set them in Settings › Secrets or on the destination.")
            }

        case "jamfusers":
            out["password"] = nil
            remapSite(&out, context: context, warnings: &warnings)
            warnings.append("Account passwords are not returned by the API; new local accounts need one set on the destination.")

        case "smartcomputergroups", "smartmobiledevicegroups":
            remapSite(&out, context: context, warnings: &warnings)

        case "staticcomputergroups", "staticmobiledevicegroups":
            remapSite(&out, context: context, warnings: &warnings)
            // members are inventory records, which are not migrated
            for field in ["assignments", "computerIds", "mobileDeviceIds", "assignedIds"] {
                out[field] = nil
            }
            warnings.append("Static group members are inventory records and are not copied; the group is created empty.")

        case "advancedmobiledevicesearches":
            remapSite(&out, context: context, warnings: &warnings)

        case "patchsoftwaretitles":
            // detail payloads may carry ids only — resolve names through the
            // source lookups before matching on the destination
            var categoryName = out["categoryName"] as? String
            if categoryName?.isEmpty != false {
                categoryName = context.sourceName("categories", id: "\(out["categoryId"] ?? "")")
            }
            if let categoryName, let destCategoryId = context.destId("categories", named: categoryName) {
                out["categoryId"] = destCategoryId
            } else {
                out["categoryId"] = "-1"
                if let categoryName {
                    warnings.append("Category \"\(categoryName)\" does not exist on the destination; the object was created without one.")
                }
            }
            out["categoryName"] = nil
            var siteName = out["siteName"] as? String
            if siteName?.isEmpty != false {
                siteName = context.sourceName("sites", id: "\(out["siteId"] ?? "")")
            }
            out["siteId"] = siteName.flatMap { context.destId("sites", named: $0) } ?? "-1"
            out["siteName"] = nil
            var updatedPackages = [[String: String]]()
            for package in out["packages"] as? [[String: Any]] ?? [] {
                let packageName = package["packageName"] as? String
                    ?? (package["packageId"] as? String).flatMap { context.sourceName("packages", id: $0) }
                    ?? ""
                if let destPackageId = context.destId("packages", named: packageName) {
                    updatedPackages.append(["packageId": destPackageId, "version": "\(package["version"] ?? "")"])
                } else {
                    warnings.append("Patch package \"\(packageName)\" does not exist on the destination and was dropped.")
                }
            }
            out["packages"] = updatedPackages

        case "appinstallers":
            for readOnlyField in ["titleAvailableInAis", "selectedVersion", "latestAvailableVersion", "versionRemoved"] {
                out[readOnlyField] = nil
            }
            out["categoryId"] = (out["categoryName"] as? String).flatMap { context.destId("categories", named: $0) } ?? "-1"
            out["categoryName"] = nil
            out["siteId"] = (out["siteName"] as? String).flatMap { context.destId("sites", named: $0) } ?? "-1"
            out["siteName"] = nil

            let smartGroupId = "\(out["smartGroupId"] ?? "")"
            // detail payloads carry only the id, not smartGroupName (verified
            // live 2026-10-04) — resolve the name through the source lookup
            var smartGroupName = out["smartGroupName"] as? String ?? ""
            if smartGroupName.isEmpty {
                smartGroupName = context.sourceName("smartcomputergroups", id: smartGroupId) ?? ""
            }
            out["smartGroupName"] = nil
            if !smartGroupId.isEmpty && smartGroupId != "-1" && smartGroupId != "<null>" {
                if let destGroupId = context.destId("smartcomputergroups", named: smartGroupName) {
                    out["smartGroupId"] = "\(destGroupId)"
                } else {
                    out["smartGroupId"] = nil
                    out["enabled"] = false
                    let groupLabel = smartGroupName.isEmpty ? "with id \(smartGroupId)" : "\"\(smartGroupName)\""
                    warnings.append("Smart group \(groupLabel) does not exist on the destination; the deployment was created without a scope and disabled.")
                }
            } else {
                // the server stores "no group" as -1; normalize absent to match
                out["smartGroupId"] = "-1"
            }
            if var selfService = out["selfServiceSettings"] as? [String: Any],
               let categories = selfService["categories"] as? [[String: Any]] {
                var updated = [[String: Any]]()
                for category in categories {
                    // detail payloads carry the category id only — resolve
                    // the name through the source lookup
                    var name = category["name"] as? String ?? ""
                    if name.isEmpty {
                        name = context.sourceName("categories", id: "\(category["id"] ?? "")") ?? ""
                    }
                    if let destCategoryId = context.destId("categories", named: name) {
                        updated.append(["id": destCategoryId, "featured": category["featured"] ?? false])
                    } else {
                        warnings.append("Self Service category \"\(name)\" does not exist on the destination and was dropped.")
                    }
                }
                selfService["categories"] = updated.isEmpty ? nil : updated
                out["selfServiceSettings"] = selfService
            }

        case "enrollmentcustomizations":
            remapSite(&out, context: context, warnings: &warnings)
            if out["brandingSettings"] != nil {
                warnings.append("Branding images are not copied; re-upload them on the destination.")
            }

        case "computerprestages", "mobiledeviceprestages":
            return transformPreStage(type: type, source: out, context: context, warnings: &warnings)

        case "blueprints":
            return transformBlueprint(source: out, context: context, warnings: &warnings)

        case "compliancebenchmarks":
            return transformBenchmark(source: out, context: context, warnings: &warnings)

        default:
            return .blocked(reason: "\(type.displayName) are not supported by this version of the app")
        }

        do {
            let body = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
            return .write(TransformedObject(body: body, contentType: "application/json", warnings: warnings))
        } catch {
            return .blocked(reason: "The payload could not be encoded: \(error.localizedDescription)")
        }
    }

    // MARK: PreStages

    private static func transformPreStage(type: ObjectType, source: [String: Any],
                                          context: TransformContext, warnings: inout [String]) -> TransformOutcome {
        var out = source
        let isUpdate: Bool
        if case .update = context.action { isUpdate = true } else { isUpdate = false }

        out["profileUuid"] = nil

        // ADE instance: devices belong to each tenant's own token
        let adeId = "\(out["deviceEnrollmentProgramInstanceId"] ?? "")"
        if !adeId.isEmpty && adeId != "0" {
            if let mapped = context.mappings.adeInstances[adeId] {
                out["deviceEnrollmentProgramInstanceId"] = mapped
            } else {
                return .blocked(reason: "No ADE instance mapping is set; map one in the Clone wizard")
            }
        }

        remapSite(&out, context: context, warnings: &warnings)
        if let enrollmentSiteId = out["enrollmentSiteId"] {
            var scratch: [String: Any] = ["siteId": enrollmentSiteId]
            remapSite(&scratch, context: context, warnings: &warnings)
            out["enrollmentSiteId"] = scratch["siteId"]
        }

        // nested blocks: the API REQUIRES id and versionLock — a POST sends
        // "-1"/0, a PUT echoes the destination's (verified live 2026-10-04)
        if var location = out["locationInformation"] as? [String: Any] {
            location["id"] = isUpdate ? (context.destPreStageIds["locationInformation"] ?? "-1") : "-1"
            remapNamedId(&location, idKey: "buildingId", lookupType: "buildings", label: "building", context: context, warnings: &warnings)
            remapNamedId(&location, idKey: "departmentId", lookupType: "departments", label: "department", context: context, warnings: &warnings)
            location["versionLock"] = isUpdate ? (context.destVersionLocks["locationInformation"] ?? 0) : 0
            out["locationInformation"] = location
        }
        if var purchasing = out["purchasingInformation"] as? [String: Any] {
            purchasing["id"] = isUpdate ? (context.destPreStageIds["purchasingInformation"] ?? "-1") : "-1"
            purchasing["versionLock"] = isUpdate ? (context.destVersionLocks["purchasingInformation"] ?? 0) : 0
            out["purchasingInformation"] = purchasing
        }
        if var accounts = out["accountSettings"] as? [String: Any] {
            accounts["id"] = isUpdate ? (context.destPreStageIds["accountSettings"] ?? "-1") : "-1"
            accounts["versionLock"] = isUpdate ? (context.destVersionLocks["accountSettings"] ?? 0) : 0
            out["accountSettings"] = accounts
            warnings.append("The admin password is not returned by the API; set it on the destination PreStage.")
        }
        out["versionLock"] = isUpdate ? context.destVersionLocks["root"] : nil

        // enrollment customization, profiles and packages by name through the id maps
        let customizationId = "\(out["enrollmentCustomizationId"] ?? "")"
        if !customizationId.isEmpty && customizationId != "0" {
            if let name = context.sourceName("enrollmentcustomizations", id: customizationId),
               let destId = context.destId("enrollmentcustomizations", named: name) {
                out["enrollmentCustomizationId"] = destId
            } else {
                out["enrollmentCustomizationId"] = "0"
                warnings.append("The enrollment customization does not exist on the destination and was cleared.")
            }
        }

        let profileType = type.key == "computerprestages" ? "osxconfigurationprofiles" : "mobiledeviceconfigurationprofiles"
        remapIdArray(&out, key: "prestageInstalledProfileIds", lookupType: profileType,
                     label: "configuration profile", context: context, warnings: &warnings)
        remapIdArray(&out, key: "customPackageIds", lookupType: "packages",
                     label: "package", context: context, warnings: &warnings)
        let profileLabels = ["pssoConfigProfileId": "Platform SSO configuration profile",
                             "rtsConfigProfileId": "return-to-service configuration profile"]
        for key in ["pssoConfigProfileId", "rtsConfigProfileId"] {
            let value = "\(out[key] ?? "")"
            guard !value.isEmpty, value != "0", value != "<null>" else { continue }
            if let name = context.sourceName(profileType, id: value),
               let destId = context.destId(profileType, named: name) {
                out[key] = destId
            } else {
                out[key] = nil
                warnings.append("The \(profileLabels[key] ?? key) does not exist on the destination and was cleared.")
            }
        }

        let dpId = "\(out["customPackageDistributionPointId"] ?? "")"
        if !dpId.isEmpty && dpId != "0" && dpId != "<null>" {
            if let mapped = context.mappings.distributionPoints[dpId] {
                out["customPackageDistributionPointId"] = mapped
            } else {
                warnings.append("The custom package distribution point is not mapped; map it in the Clone wizard.")
            }
        }

        // a manual Recovery Lock password is never returned by the API but is
        // required when enabled — take it from Settings › Secrets or write a
        // placeholder (verified live 2026-10-04: omitting it is a 400)
        if out["enableRecoveryLock"] as? Bool == true,
           "\(out["recoveryLockPasswordType"] ?? "")" == "MANUAL" {
            out["recoveryLockPassword"] = context.secrets["recoverylock"] ?? placeholderSecret
            if context.secrets["recoverylock"] == nil {
                warnings.append("The Recovery Lock password is not returned by the API; a placeholder was written — change it on the destination.")
            }
        }

        if out["defaultPrestage"] as? Bool == true {
            warnings.append("This is the default PreStage; migrate it last if other PreStages change the default.")
        }

        do {
            let body = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
            return .write(TransformedObject(body: body, contentType: "application/json", warnings: warnings))
        } catch {
            return .blocked(reason: "The payload could not be encoded: \(error.localizedDescription)")
        }
    }

    // MARK: Blueprints

    private static func transformBlueprint(source: [String: Any],
                                           context: TransformContext, warnings: inout [String]) -> TransformOutcome {
        var out = source
        for readOnly in ["id", "created", "updated", "deploymentState"] {
            out[readOnly] = nil
        }

        // device groups are referenced by groupPlatformId UUID
        if var scope = out["scope"] as? [String: Any], let groups = scope["deviceGroups"] as? [String] {
            var remapped = [String]()
            for uuid in groups {
                if let name = context.sourceName(platformGroupsKey, id: uuid),
                   let destUuid = context.destId(platformGroupsKey, named: name) {
                    remapped.append(destUuid)
                } else {
                    return .blocked(reason: "A scoped device group does not exist on the destination")
                }
            }
            scope["deviceGroups"] = remapped
            out["scope"] = scope
        }
        if var predicate = out["activationPredicate"] as? String, !predicate.isEmpty {
            for (uuid, name) in context.sourceNamesById[platformGroupsKey] ?? [:] where predicate.contains(uuid) {
                guard let destUuid = context.destId(platformGroupsKey, named: name) else {
                    return .blocked(reason: "The activation predicate references a device group that does not exist on the destination")
                }
                predicate = predicate.replacingOccurrences(of: uuid, with: destUuid)
            }
            out["activationPredicate"] = predicate
        }

        // configuration-profile components get fresh payload identifiers;
        // app-managed components reference the source tenant's VPP assets
        out = reassignPayloadIdentifiers(in: out, forComparison: context.isForComparison) { note in
            if note == "app-managed" {
                warnings.append("An app-managed component references VPP assets that belong to the source tenant; check it on the destination.")
            }
        } as? [String: Any] ?? out

        do {
            let body = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
            return .write(TransformedObject(body: body, contentType: "application/json", warnings: warnings))
        } catch {
            return .blocked(reason: "The payload could not be encoded: \(error.localizedDescription)")
        }
    }

    private static func reassignPayloadIdentifiers(in value: Any, forComparison: Bool, note: (String) -> Void) -> Any {
        if var dict = value as? [String: Any] {
            if dict["payloadIdentifier"] is String {
                // every write needs fresh identifiers; a diff needs stable
                // ones, or identical blueprints would never compare equal
                dict["payloadIdentifier"] = forComparison ? "(payload-identifier)" : UUID().uuidString
            }
            if let type = dict["type"] as? String, type.contains("app-managed") {
                note("app-managed")
            }
            for (key, nested) in dict {
                dict[key] = reassignPayloadIdentifiers(in: nested, forComparison: forComparison, note: note)
            }
            return dict
        }
        if let array = value as? [Any] {
            return array.map { reassignPayloadIdentifiers(in: $0, forComparison: forComparison, note: note) }
        }
        return value
    }

    // MARK: Compliance Benchmarks

    private static func transformBenchmark(source: [String: Any],
                                           context: TransformContext, warnings: inout [String]) -> TransformOutcome {
        // the POST shape differs from the GET shape: only known fields go out,
        // and the source's baselineId becomes sourceBaselineId
        var out = [String: Any]()
        out["title"] = source["title"]
        if let description = source["description"] { out["description"] = description }
        if let enforcementMode = source["enforcementMode"] { out["enforcementMode"] = enforcementMode }
        if let versions = source["selectedOsVersions"] { out["selectedOsVersions"] = versions }
        out["sourceBaselineId"] = source["baselineId"] ?? source["sourceBaselineId"]
        if let rules = source["rules"] as? [[String: Any]] {
            out["rules"] = rules.map { rule -> [String: Any] in
                var trimmed = [String: Any]()
                trimmed["id"] = rule["id"]
                if let enabled = rule["enabled"] { trimmed["enabled"] = enabled }
                if let odv = rule["odv"] { trimmed["odv"] = odv }
                return trimmed
            }
        }
        if var target = source["target"] as? [String: Any], let groups = target["deviceGroups"] as? [String] {
            var remapped = [String]()
            for uuid in groups {
                if let name = context.sourceName(platformGroupsKey, id: uuid),
                   let destUuid = context.destId(platformGroupsKey, named: name) {
                    remapped.append(destUuid)
                } else {
                    return .blocked(reason: "A targeted device group does not exist on the destination")
                }
            }
            target["deviceGroups"] = remapped
            out["target"] = target
        }

        do {
            let body = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
            return .write(TransformedObject(body: body, contentType: "application/json", warnings: warnings))
        } catch {
            return .blocked(reason: "The payload could not be encoded: \(error.localizedDescription)")
        }
    }

    /// Remaps an id field via the source name and destination id lookups.
    private static func remapNamedId(_ json: inout [String: Any], idKey: String, lookupType: String,
                                     label: String, context: TransformContext, warnings: inout [String]) {
        let value = "\(json[idKey] ?? "")"
        guard !value.isEmpty, value != "-1", value != "0", value != "<null>" else { return }
        if let name = context.sourceName(lookupType, id: value),
           let destId = context.destId(lookupType, named: name) {
            json[idKey] = destId
        } else {
            json[idKey] = "-1"
            warnings.append("The \(label) does not exist on the destination and was cleared.")
        }
    }

    /// Remaps an array of ids, dropping entries that don't exist on the destination.
    private static func remapIdArray(_ json: inout [String: Any], key: String, lookupType: String,
                                     label: String, context: TransformContext, warnings: inout [String]) {
        guard let ids = json[key] as? [Any] else { return }
        var remapped = [String]()
        for id in ids {
            let value = "\(id)"
            if let name = context.sourceName(lookupType, id: value),
               let destId = context.destId(lookupType, named: name) {
                remapped.append(destId)
            } else {
                warnings.append("A \(label) referenced by the PreStage does not exist on the destination and was dropped.")
            }
        }
        json[key] = remapped
    }

    /// Remaps categoryId/categoryName to the destination's category.
    private static func remapCategory(_ json: inout [String: Any], context: TransformContext, warnings: inout [String]) {
        var name = json["categoryName"] as? String
        if name == nil || name?.isEmpty == true {
            let sourceId = "\(json["categoryId"] ?? "")"
            if !sourceId.isEmpty && sourceId != "-1" {
                name = context.sourceName("categories", id: sourceId)
            }
        }
        guard let name, !name.isEmpty, name != "NONE", name != "No category assigned" else {
            json["categoryId"] = "-1"
            json["categoryName"] = nil
            return
        }
        if let destId = context.destId("categories", named: name) {
            json["categoryId"] = destId
            if json["categoryName"] != nil { json["categoryName"] = name }
        } else {
            warnings.append("Category \"\(name)\" does not exist on the destination; the object was created without one.")
            json["categoryId"] = "-1"
            json["categoryName"] = nil
        }
    }

    /// Remaps siteId to the destination's site (source id → name → destination id).
    private static func remapSite(_ json: inout [String: Any], context: TransformContext, warnings: inout [String]) {
        let sourceSiteId = "\(json["siteId"] ?? "")"
        guard !sourceSiteId.isEmpty, sourceSiteId != "-1", sourceSiteId != "<null>" else {
            json["siteId"] = "-1"
            return
        }
        if let siteName = context.sourceName("sites", id: sourceSiteId),
           let destSiteId = context.destId("sites", named: siteName) {
            json["siteId"] = destSiteId
        } else {
            warnings.append("The site does not exist on the destination; the object was created without one.")
            json["siteId"] = "-1"
        }
    }
}
