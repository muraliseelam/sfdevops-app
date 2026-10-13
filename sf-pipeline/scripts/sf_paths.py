#!/usr/bin/env python3
"""sf_paths.py — map an sfdx source path to the metadata component it belongs to.

    path_to_component("force-app/main/default/classes/Foo.cls-meta.xml") -> ("ApexClass", "Foo")

Used by the commit workflow (to tell the hub which components a commit touched) and anywhere
else that needs a stable component identity: the Unique ID is "Type:Member", identical
across work items, so overlaps can be joined on it.
"""

import os
import re

# folder -> (metadata type, how the member name is derived)
#   "file"   first path segment after the folder, minus its suffixes
#   "bundle" first path segment after the folder (a directory bundle)
FOLDERS = {
    "classes": ("ApexClass", "file"),
    "triggers": ("ApexTrigger", "file"),
    "pages": ("ApexPage", "file"),
    "components": ("ApexComponent", "file"),
    "lwc": ("LightningComponentBundle", "bundle"),
    "aura": ("AuraDefinitionBundle", "bundle"),
    "layouts": ("Layout", "file"),
    "permissionsets": ("PermissionSet", "file"),
    "permissionsetgroups": ("PermissionSetGroup", "file"),
    "profiles": ("Profile", "file"),
    "flows": ("Flow", "file"),
    "flexipages": ("FlexiPage", "file"),
    "tabs": ("CustomTab", "file"),
    "applications": ("CustomApplication", "file"),
    "staticresources": ("StaticResource", "file"),
    "customMetadata": ("CustomMetadata", "file"),
    "customPermissions": ("CustomPermission", "file"),
    "quickActions": ("QuickAction", "file"),
    "globalValueSets": ("GlobalValueSet", "file"),
    "email": ("EmailTemplate", "nested"),
    "reports": ("Report", "nested"),
    "dashboards": ("Dashboard", "nested"),
    "documents": ("Document", "nested"),
    "namedCredentials": ("NamedCredential", "file"),
    "externalCredentials": ("ExternalCredential", "file"),
    "connectedApps": ("ConnectedApp", "file"),
    "remoteSiteSettings": ("RemoteSiteSetting", "file"),
    "settings": ("Settings", "file"),
    "workflows": ("Workflow", "file"),
    "contentassets": ("ContentAsset", "file"),
    "sharingRules": ("SharingRules", "file"),
    "queues": ("Queue", "file"),
    "groups": ("Group", "file"),
    "roles": ("Role", "file"),
    "translations": ("Translations", "file"),
    "objectTranslations": ("CustomObjectTranslation", "bundle"),
    "standardValueSets": ("StandardValueSet", "file"),
    "messageChannels": ("LightningMessageChannel", "file"),
    "notificationtypes": ("CustomNotificationType", "file"),
    "pathAssistants": ("PathAssistant", "file"),
    "duplicateRules": ("DuplicateRule", "file"),
    "matchingRules": ("MatchingRules", "file"),
    "assignmentRules": ("AssignmentRules", "file"),
    "autoResponseRules": ("AutoResponseRules", "file"),
    "escalationRules": ("EscalationRules", "file"),
    "cspTrustedSites": ("CspTrustedSite", "file"),
    "corsWhitelistOrigins": ("CorsWhitelistOrigin", "file"),
    "certs": ("Certificate", "file"),
    "authproviders": ("AuthProvider", "file"),
}

# objects/<Object>/<sub>/<Member>.<suffix>-meta.xml -> child type, member "Object.Member"
OBJECT_CHILDREN = {
    "fields": "CustomField",
    "listViews": "ListView",
    "recordTypes": "RecordType",
    "validationRules": "ValidationRule",
    "webLinks": "WebLink",
    "compactLayouts": "CompactLayout",
    "fieldSets": "FieldSet",
    "businessProcesses": "BusinessProcess",
    "sharingReasons": "SharingReason",
    "indexes": "Index",
}

SUFFIX = re.compile(r"(\.[A-Za-z0-9_]+)?(-meta\.xml)?$")


def _strip_suffix(name):
    if name.endswith("-meta.xml"):
        name = name[: -len("-meta.xml")]
    return name.rsplit(".", 1)[0] if "." in name else name


def path_to_component(path):
    """Return (type, member) for a source path, or ("Unknown", path) when unrecognised."""
    parts = path.replace("\\", "/").split("/")
    try:
        i = parts.index("default")
        rel = parts[i + 1:]
    except ValueError:
        rel = parts
        for j, p in enumerate(parts):
            if p in FOLDERS or p in ("objects", "labels"):
                rel = parts[j:]
                break
    if not rel:
        return ("Unknown", path)
    folder = rel[0]
    if folder == "labels":
        return ("CustomLabels", "CustomLabels")
    if folder == "objects" and len(rel) >= 2:
        obj = rel[1]
        if len(rel) == 3:
            return ("CustomObject", obj)
        if len(rel) >= 4 and rel[2] in OBJECT_CHILDREN:
            return (OBJECT_CHILDREN[rel[2]], f"{obj}.{_strip_suffix(rel[3])}")
        return ("CustomObject", obj)
    if folder in FOLDERS and len(rel) >= 2:
        mtype, how = FOLDERS[folder]
        if how == "bundle":
            return (mtype, rel[1])
        if how == "nested" and len(rel) >= 3:
            return (mtype, f"{rel[1]}/{_strip_suffix(rel[2])}")
        return (mtype, _strip_suffix(rel[1]))
    return ("Unknown", path)


def unique_id(path):
    t, m = path_to_component(path)
    return f"{t}:{m}"


if __name__ == "__main__":
    import sys

    for arg in sys.argv[1:]:
        print(f"{arg} -> {unique_id(arg)}")
