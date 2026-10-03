//
//  ClassicTransformer.swift
//  JamfMigrator
//
//  Per-type rewriting of Classic XML payloads before they are written to the
//  destination. Ported from the legacy Cleanup.Xml.
//

import Foundation

enum ClassicTransformer {

    /// Rewrites a source object's Classic XML for the destination.
    static func transform(type: ObjectType, xml: String, context: TransformContext) -> TransformOutcome {
        var out = xml
        var warnings = [String]()
        var icon: SelfServiceIcon? = nil
        var createPathOverride: String? = nil

        // every nested <id> is stripped; Classic resolves references by name
        out = ClassicXML.strippingTag("id", from: out)

        switch type.key {
        case "sites", "softwareupdateservers", "printers", "dockitems", "userextensionattributes":
            break

        case "networksegments":
            // netboot/distribution servers and JCDS URLs don't transfer
            out = ClassicXML.replacing(pattern: "<distribution_server>(.*?)</distribution_server>", in: out, with: "<distribution_server/>")
            if ClassicXML.value(of: "distribution_point", in: out) == "Cloud Distribution Point" {
                out = ClassicXML.replacing(pattern: "<url>(.*?)</url>", in: out, with: "<url/>")
            }
            if !context.includedTypes.contains("softwareupdateservers") {
                out = ClassicXML.replacing(pattern: "<swu_server>(.*?)</swu_server>", in: out, with: "<swu_server/>")
            }

        case "ldapservers", "directorybindings":
            // the API only returns a hash; write the secret from Settings or a placeholder
            let secret = context.secrets[type.key == "ldapservers" ? "ldap" : "bind"] ?? placeholderSecret
            if out.contains("password_sha256") {
                out = ClassicXML.replacing(pattern: "<password_sha256[^>]*>(.*?)</password_sha256>", in: out,
                                           with: "<password>\(ClassicXML.escape(secret))</password>")
                if context.secrets[type.key == "ldapservers" ? "ldap" : "bind"] == nil {
                    warnings.append("The \(type.key == "ldapservers" ? "LDAP" : "bind") password is not returned by the API; a placeholder was written.")
                }
            }

        case "users":
            out = ClassicXML.replacing(pattern: "<self_service_icon>(.|\\n|\\r)*?</self_service_icon>", in: out, with: "<self_service_icon/>")
            for tag in ["enable_custom_photo_url", "custom_photo_url", "links", "ldap_server"] {
                out = ClassicXML.strippingTag(tag, from: out)
            }

        case "usergroups":
            // member detail fields conflict on the destination
            for tag in ["full_name", "phone_number", "email_address"] {
                out = ClassicXML.strippingTag(tag, from: out)
            }

        case "jamfgroups":
            // passwords never transfer; group payloads have none, but strip defensively
            out = ClassicXML.replacing(pattern: "<password_sha256[^>]*>(.*?)</password_sha256>", in: out, with: "")
            // LDAP reference needs the destination server's id
            let ldapName = ClassicXML.value(of: "name", in: ClassicXML.value(of: "ldap_server", in: out))
            if !ldapName.isEmpty {
                if let destLdapId = context.destId("ldapservers", named: ldapName) {
                    out = ClassicXML.replacing(pattern: "<ldap_server>(.|\\n|\\r)*?</ldap_server>", in: out,
                                               with: "<ldap_server><id>\(destLdapId)</id></ldap_server>")
                } else {
                    return .blocked(reason: "LDAP server \"\(ldapName)\" does not exist on the destination")
                }
            }

        case "advancedcomputersearches":
            out = ClassicXML.strippingTag("computers", from: out)

        case "advancedusersearches":
            out = ClassicXML.strippingTag("users", from: out)

        case "classes":
            if ClassicXML.value(of: "source", in: out) == "Apple School Manager" {
                return .blocked(reason: "Apple School Manager classes are not migrated")
            }
            for tag in ["student_ids", "teacher_ids", "student_group_ids", "teacher_group_ids", "mobile_device_group_ids"] {
                out = ClassicXML.strippingTag(tag, from: out)
            }

        case "osxconfigurationprofiles", "mobiledeviceconfigurationprofiles":
            if type.key == "osxconfigurationprofiles",
               ClassicXML.value(of: "payloads", in: out).range(of: "com.apple.security.FDERecoveryKeyEscrow", options: .caseInsensitive) != nil {
                return .blocked(reason: "FileVault payloads are not migrated and must be recreated manually")
            }
            // double-encoded & in profile names breaks the payload
            out = out.replacingOccurrences(of: "&amp;amp;", with: "%26;")
            // limitations/exclusions LDAP references don't resolve
            out = ClassicXML.strippingTag("limit_to_users", from: out)
            // keep the destination profile's UUID on update so devices update in place
            if case .update = context.action, let destUUID = context.destProfileUUID, !destUUID.isEmpty {
                let sourceUUID = ClassicXML.value(of: "uuid", in: ClassicXML.value(of: "general", in: xml))
                if !sourceUUID.isEmpty {
                    out = out.replacingOccurrences(of: sourceUUID, with: destUUID)
                }
            }

        case "ebooks", "restrictedsoftware":
            break

        case "policies", "macapplications", "mobiledeviceapplications":
            // self-service icon: captured here, copied by the engine after the write
            if out.contains("</self_service_icon>") {
                let iconXml = ClassicXML.value(of: "self_service_icon", in: xml)
                let iconName = ClassicXML.value(of: "filename", in: iconXml)
                var iconUri = ClassicXML.value(of: "uri", in: iconXml)
                if type.key != "policies", let index = iconUri.firstIndex(of: "&") {
                    iconUri = String(iconUri.prefix(upTo: index))
                }
                let iconId = Self.iconId(fromUri: iconUri)
                if !iconId.isEmpty && iconId != "0" {
                    icon = SelfServiceIcon(name: iconName, sourceId: iconId)
                }
            }
            if type.key != "policies" {
                // VPP licences belong to each tenant's own token
                out = ClassicXML.replacing(pattern: "<vpp>(.*?)</vpp>", in: out,
                                           with: "<vpp><assign_vpp_device_based_licenses>false</assign_vpp_device_based_licenses><vpp_admin_account_id>-1</vpp_admin_account_id></vpp>")
                warnings.append("VPP assignment was reset; licences belong to the destination tenant's own token.")
            }
            // names that start with a space lose it on create
            out = ClassicXML.replacing(pattern: "<name> ", in: out, with: "<name>&#xA0;")
            for tag in ["limit_to_users", "open_firmware_efi_password", "self_service_icon"] {
                out = ClassicXML.strippingTag(tag, from: out)
            }
            // the accounts payload only returns a hash
            if out.contains("password_sha256") {
                out = ClassicXML.replacing(pattern: "<password_sha256[^>]*>(.*?)</password_sha256>", in: out,
                                           with: "<password>jamfchangeme</password>")
                warnings.append("A managed-account password was replaced with \"jamfchangeme\"; set the real one on the destination.")
            }
            out = ClassicXML.replacing(pattern: "<management_password_sha256[^>]*>(.*?)</management_password_sha256>", in: out, with: "")

        case "patchpolicies":
            // created under the destination's patch title
            let sourceTitleId = ClassicXML.value(of: "software_title_configuration_id", in: xml)
            guard let sourceTitleName = context.sourceName("patchsoftwaretitles", id: sourceTitleId),
                  let destTitleId = context.destId("patchsoftwaretitles", named: sourceTitleName) else {
                return .blocked(reason: "The patch title for this policy does not exist on the destination")
            }
            out = ClassicXML.strippingTag("software_title_configuration_id", from: out)
            createPathOverride = "proclassic/patchpolicies/softwaretitleconfig/id/\(destTitleId)"

        default:
            return .blocked(reason: "No Classic transform for \(type.key)")
        }

        guard let body = out.data(using: .utf8) else {
            return .blocked(reason: "The payload is not valid UTF-8")
        }
        return .write(TransformedObject(body: body,
                                        contentType: "application/xml",
                                        createPathOverride: createPathOverride,
                                        warnings: warnings,
                                        icon: icon))
    }

    /// The icon id from a self-service icon URI (…?id=123 or …/123).
    static func iconId(fromUri uri: String) -> String {
        guard !uri.isEmpty else { return "0" }
        if let index = uri.firstIndex(of: "=") {
            let after = uri.suffix(from: index).dropFirst()
            if let amp = after.firstIndex(of: "&") {
                return String(after.prefix(upTo: amp))
            }
            return String(after)
        }
        return uri.split(separator: "/").last.map(String.init) ?? "0"
    }
}
