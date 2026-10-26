import Foundation

enum LocalEndpointUtilities {
/// Builds a chat-completions endpoint URL from a user-provided base URL.
/// The base may already include a versioned root (e.g., https://openrouter.ai/api/v1,
/// https://open.bigmodel.cn/api/paas/v4) or a full `/chat/completions` path.
static func chatCompletionsURL(baseURL: String) -> URL? {
  let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return nil }
  guard var components = URLComponents(string: trimmed) else { return nil }

  var normalizedPath = sanitize(components.path)
  let targetPath = "/v1/chat/completions"

  if normalizedPath.isEmpty {
    normalizedPath = targetPath
  } else if normalizedPath.hasSuffix("/chat/completions") {
    // already points to a chat-completions endpoint – keep as-is
  } else if isVersionedRoot(normalizedPath) {
    // versioned API root such as /v1 or /v4 – append just the resource
    normalizedPath.append(contentsOf: "/chat/completions")
  } else if normalizedPath == "/" {
    normalizedPath = targetPath
  } else {
    normalizedPath.append(contentsOf: targetPath)
  }

  if !normalizedPath.hasPrefix("/") {
    normalizedPath = "/" + normalizedPath
  }

  components.path = normalizedPath
  return components.url
}

private static func isVersionedRoot(_ path: String) -> Bool {
  let last = path.split(separator: "/").last.map(String.init) ?? ""
  guard last.count > 1, last.lowercased().hasPrefix("v") else { return false }
  return Int(last.dropFirst()) != nil
}

  private static func sanitize(_ path: String) -> String {
    guard !path.isEmpty else { return "" }
    var normalized = path
    while normalized.contains("//") {
      normalized = normalized.replacingOccurrences(of: "//", with: "/")
    }
    while normalized.count > 1 && normalized.hasSuffix("/") {
      normalized.removeLast()
    }
    return normalized
  }
}
