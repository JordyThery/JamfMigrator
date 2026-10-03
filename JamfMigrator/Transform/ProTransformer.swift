//
//  ProTransformer.swift
//  JamfMigrator
//
//  Per-type rewriting of Jamf Pro API JSON payloads before they are written
//  to the destination. Ported from the legacy Cleanup.Json, extended to the
//  types that moved from Classic to the Pro API.
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
            warnings.append("File-share passwords are not returned by the API; set them on the destination.")

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
            warnings.append("Static group members are inventory records and were not copied; the group is created empty.")

        case "advancedmobiledevicesearches":
            remapSite(&out, context: context, warnings: &warnings)

        case "patchsoftwaretitles":
            // ported 1:1 from Cleanup.Json
            if let categoryName = out["categoryName"] as? String,
               let destCategoryId = context.destId("categories", named: categoryName) {
                out["categoryId"] = destCategoryId
            } else {
                out["categoryId"] = "-1"
            }
            out["categoryName"] = nil
            out["siteId"] = (out["siteName"] as? String).flatMap { context.destId("sites", named: $0) } ?? "-1"
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
            let smartGroupName = out["smartGroupName"] as? String ?? ""
            out["smartGroupName"] = nil
            if !smartGroupId.isEmpty && smartGroupId != "-1" && smartGroupId != "<null>" {
                if let destGroupId = context.destId("smartcomputergroups", named: smartGroupName) {
                    out["smartGroupId"] = "\(destGroupId)"
                } else {
                    out["smartGroupId"] = nil
                    out["enabled"] = false
                    warnings.append("Smart group \"\(smartGroupName)\" does not exist on the destination; the deployment was created without a scope and disabled.")
                }
            }
            if var selfService = out["selfServiceSettings"] as? [String: Any],
               let categories = selfService["categories"] as? [[String: Any]] {
                var updated = [[String: Any]]()
                for category in categories {
                    let name = category["name"] as? String ?? ""
                    if let destCategoryId = context.destId("categories", named: name) {
                        updated.append(["id": destCategoryId, "featured": category["featured"] ?? false])
                    } else {
                        warnings.append("Self Service category \"\(name)\" does not exist on the destination and was dropped.")
                    }
                }
                selfService["categories"] = updated.isEmpty ? nil : updated
                out["selfServiceSettings"] = selfService
            }

        default:
            return .blocked(reason: "No Pro transform for \(type.key)")
        }

        do {
            let body = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
            return .write(TransformedObject(body: body, contentType: "application/json", warnings: warnings))
        } catch {
            return .blocked(reason: "The payload could not be encoded: \(error.localizedDescription)")
        }
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
            warnings.append("Category \"\(name)\" does not exist on the destination; the object was filed without one.")
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
            warnings.append("The object's site does not exist on the destination; it was filed under None.")
            json["siteId"] = "-1"
        }
    }
}
