import MCP

/// Compact feature names derived from the connected provider's advertised schema.
enum BrowserMCPProviderFeatures {
    static func detect(in tools: [Tool]) -> [String] {
        var features = Set<String>()
        let actions: Set<String> = [
            "click",
            "dblclick",
            "fill",
            "hover",
            "type",
            "press",
            "paste",
            "copy",
            "check",
            "uncheck",
            "select",
            "read",
            "read-all",
            "wait",
            "count",
        ]
        for tool in tools {
            let properties = tool.inputSchema.objectValue?["properties"]?.objectValue
            if tool.name == "peekaboo_locator_action",
               let advertised = properties?["action"]?.objectValue?["enum"]?.arrayValue
            {
                if Set(advertised.compactMap(\.stringValue))
                    .isSuperset(of: ["clipboard-read", "clipboard-write", "paste"]),
                    properties?["items"]?.objectValue?["type"] == .string("array")
                {
                    features.insert("clipboard:session")
                }
                for value in advertised {
                    if let action = value.stringValue, actions.contains(action) {
                        features.insert("locator:\(action)")
                    }
                }
            }
            if tool.name == "peekaboo_locator_action",
               let pattern = properties?["fields"]?.objectValue?["items"]?.objectValue?["pattern"]?.stringValue,
               pattern.contains("|visible|")
            {
                features.insert("locator:visibleField")
            }
            if tool.name == "peekaboo_locator_action",
               let pattern = properties?["fields"]?.objectValue?["items"]?.objectValue?["pattern"]?.stringValue,
               pattern.contains("|enabled|")
            {
                features.insert("locator:enabledField")
            }
            if tool.name == "peekaboo_locator_action",
               let buttons = properties?["button"]?.objectValue?["enum"]?.arrayValue,
               let modifiers = properties?["modifiers"]?.objectValue?["items"]?.objectValue?["enum"]?.arrayValue,
               Set(buttons.compactMap(\.stringValue)).isSuperset(of: ["left", "right", "middle"]),
               Set(modifiers.compactMap(\.stringValue))
                   .isSuperset(of: ["Alt", "Control", "Meta", "Shift", "ControlOrMeta"])
            {
                features.insert("locator:clickOptions")
            }
            if tool.name == "peekaboo_locator_action",
               let queries = properties?["query"]?.objectValue?["anyOf"]?.arrayValue,
               queries.contains(where: { query in
                   let schema = query.objectValue
                   let fields = schema?["properties"]?.objectValue
                   return schema?["required"]?.arrayValue?.contains(.string("role")) == true &&
                       fields?["role"]?.objectValue != nil &&
                       self.acceptsString(fields?["name"])
               })
            {
                features.insert("locator:role")
            }
            if tool.name == "peekaboo_locator_action",
               let queries = properties?["query"]?.objectValue?["anyOf"]?.arrayValue,
               queries.contains(where: { query in
                   let schema = query.objectValue
                   let fields = schema?["properties"]?.objectValue
                   return schema?["required"]?.arrayValue?.contains(.string("text")) == true &&
                       fields?["text"]?.objectValue != nil &&
                       fields?["exact"]?.objectValue?["type"] == .string("boolean")
               })
            {
                features.insert("locator:text")
            }
            if tool.name == "peekaboo_locator_action",
               let queries = properties?["query"]?.objectValue?["anyOf"]?.arrayValue,
               let fields = queries.first?.objectValue?["properties"]?.objectValue,
               self.acceptsString(fields["hasText"]),
               self.acceptsString(fields["hasNotText"]),
               fields["nth"]?.objectValue?["type"] == .string("integer")
            {
                features.insert("locator:refinements")
            }
            if tool.name == "peekaboo_locator_action",
               let queries = properties?["query"]?.objectValue?["anyOf"]?.arrayValue,
               queries.first?.objectValue?["properties"]?.objectValue?["visible"]?.objectValue?["type"] ==
               .string("boolean")
            {
                features.insert("locator:visibility")
            }
            if tool.name == "peekaboo_locator_action",
               let queries = properties?["query"]?.objectValue?["anyOf"]?.arrayValue,
               let fields = queries.first?.objectValue?["properties"]?.objectValue,
               let has = fields["has"]?.objectValue,
               let hasNot = fields["hasNot"]?.objectValue,
               has["anyOf"]?.arrayValue != nil || has["$ref"]?.stringValue != nil,
               hasNot["anyOf"]?.arrayValue != nil || hasNot["$ref"]?.stringValue != nil
            {
                features.insert("locator:descendants")
            }
            if tool.name == "peekaboo_locator_action",
               let queries = properties?["query"]?.objectValue?["anyOf"]?.arrayValue,
               let fields = queries.first?.objectValue?["properties"]?.objectValue,
               let has = fields["and"]?.objectValue,
               let hasNot = fields["or"]?.objectValue,
               has["anyOf"]?.arrayValue != nil || has["$ref"]?.stringValue != nil,
               hasNot["anyOf"]?.arrayValue != nil || hasNot["$ref"]?.stringValue != nil
            {
                features.insert("locator:composition")
            }
            if tool.name == "peekaboo_locator_action",
               let queries = properties?["query"]?.objectValue?["anyOf"]?.arrayValue,
               let children = queries.first?.objectValue?["properties"]?.objectValue?["has"]?
                   .objectValue?["anyOf"]?.arrayValue,
                   children.contains(where: { child in
                       child.objectValue?["required"]?.arrayValue?.contains(.string("role")) == true
                   })
            {
                features.insert("locator:nestedRole")
            }
            if tool.name == "peekaboo_locator_action",
               let queries = properties?["query"]?.objectValue?["anyOf"]?.arrayValue,
               ["text", "label", "placeholder", "name", "hasText", "hasNotText"].allSatisfy({ name in
                   queries.contains { query in
                       let field = query.objectValue?["properties"]?.objectValue?[name]
                       return field?.objectValue?["anyOf"]?.arrayValue?.contains { option in
                           let fields = option.objectValue?["properties"]?.objectValue
                           return fields?["regex"]?.objectValue?["type"] == .string("string") &&
                               fields?["flags"]?.objectValue?["type"] == .string("string")
                       } == true
                   }
               })
            {
                features.insert("locator:regex")
            }
            features.formUnion(self.transferFeatures(tool))
            features.formUnion(self.navigationFeatures(tool))
            features.formUnion(self.assetFeatures(tool))
        }
        return features.sorted()
    }

    private static func transferFeatures(_ tool: Tool) -> Set<String> {
        var features = Set<String>()
        let properties = tool.inputSchema.objectValue?["properties"]?.objectValue
        if tool.name == "get_network_request",
           let formats = properties?["documentFormat"]?.objectValue?["enum"]?.arrayValue,
           Set(formats.compactMap(\.stringValue)).isSuperset(of: ["pdf", "md", "xlsx", "csv", "docx", "pptx"])
        {
            features.insert("export:workspace")
        }
        if tool.name == "upload_file",
           properties?["filePaths"]?.objectValue?["type"] == .string("array"),
           properties?["filePaths"]?.objectValue?["items"]?.objectValue?["type"] == .string("string")
        {
            features.insert("upload:multiple")
        }
        if tool.name == "peekaboo_locator_action",
           let states = properties?["download"]?.objectValue?["properties"]?.objectValue?["state"]?
               .objectValue?["enum"]?.arrayValue,
               states.contains(.string("started")), states.contains(.string("completed"))
        {
            features.insert("locator:expectDownload")
        }
        return features
    }

    private static func assetFeatures(_ tool: Tool) -> Set<String> {
        let properties = tool.inputSchema.objectValue?["properties"]?.objectValue
        let assets = properties?["assets"]?.objectValue
        let fields = assets?["items"]?.objectValue?["properties"]?.objectValue
        guard tool.name == "get_network_request",
              assets?["maxItems"] == .int(16),
              fields?["id"]?.objectValue?["type"] == .string("string"),
              fields?["url"]?.objectValue?["type"] == .string("string"),
              properties?["expectedURL"]?.objectValue?["type"] == .string("string"),
              properties?["responseFilePath"]?.objectValue?["type"] == .string("string")
        else { return [] }
        return ["assets:capturedBundle"]
    }

    private static func navigationFeatures(_ tool: Tool) -> Set<String> {
        var features = Set<String>()
        let properties = tool.inputSchema.objectValue?["properties"]?.objectValue
        if tool.name == "peekaboo_locator_action",
           let navigation = properties?["navigation"]?.objectValue?["properties"]?.objectValue,
           navigation["url"]?.objectValue?["anyOf"]?.arrayValue != nil,
           navigation["loadState"]?.objectValue?["enum"]?.arrayValue != nil,
           navigation["timeout"]?.objectValue?["type"] == .string("integer")
        {
            features.insert("locator:expectNavigation")
            if navigation["loadState"]?.objectValue?["enum"]?.arrayValue?.contains(.string("commit")) == true {
                features.insert("locator:commit")
            }
        }
        if tool.name == "wait_for",
           properties?["url"]?.objectValue?["anyOf"]?.arrayValue != nil,
           let states = properties?["loadState"]?.objectValue?["enum"]?.arrayValue,
           Set(states.compactMap(\.stringValue)).isSuperset(of: ["domcontentloaded", "load", "networkidle"])
        {
            features.insert("wait:page")
        }
        if tool.name == "evaluate_script",
           properties?["skipNavigationWait"]?.objectValue?["type"] == .string("boolean"),
           properties?["waitForStableDom"]?.objectValue?["type"] == .string("boolean")
        {
            features.insert("read:skipNavigationWait")
        }
        return features
    }

    private static func acceptsString(_ schema: Value?) -> Bool {
        schema?.objectValue?["type"] == .string("string") ||
            schema?.objectValue?["anyOf"]?.arrayValue?.contains {
                $0.objectValue?["type"] == .string("string")
            } == true
    }
}
