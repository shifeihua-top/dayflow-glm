import Foundation

enum OpenAICompatiblePreset: String, Codable, CaseIterable {
  case openRouter = "openrouter"
  case zhipuGLM = "zhipu_glm"
  case custom

  var presetDisplayName: String {
    switch self {
    case .openRouter: return "OpenRouter"
    case .zhipuGLM: return "智谱 GLM"
    case .custom: return String(localized: "Custom")
    }
  }
}

struct OpenAICompatibleConfiguration: Codable, Equatable {
  static let openRouterBaseURL = "https://openrouter.ai/api/v1"
  static let zhipuGLMBaseURL = "https://open.bigmodel.cn/api/paas/v4"
  // Dayflow sends a screenshot with every analysis request, so the default
  // model must accept image input; text-only GLM models cannot describe frames.
  static let zhipuGLMDefaultModelID = "glm-4.6v"

  let preset: OpenAICompatiblePreset
  let baseURL: String
  let modelID: String

  init(preset: OpenAICompatiblePreset, baseURL: String, modelID: String) {
    self.preset = preset
    self.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    self.modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func openRouter(modelID: String = "") -> OpenAICompatibleConfiguration {
    OpenAICompatibleConfiguration(
      preset: .openRouter,
      baseURL: openRouterBaseURL,
      modelID: modelID
    )
  }

  static func zhipuGLM(modelID: String = zhipuGLMDefaultModelID) -> OpenAICompatibleConfiguration {
    OpenAICompatibleConfiguration(
      preset: .zhipuGLM,
      baseURL: zhipuGLMBaseURL,
      modelID: modelID
    )
  }

  var chatCompletionsURL: URL? {
    LocalEndpointUtilities.chatCompletionsURL(baseURL: baseURL)
  }

  var isComplete: Bool {
    !baseURL.isEmpty && !modelID.isEmpty && chatCompletionsURL != nil
  }
}

enum OpenAICompatiblePreferences {
  static let keychainProvider = "openai_compatible"
  private static let configurationKey = "llmOpenAICompatibleConfigurationV1"

  static func load(from defaults: UserDefaults = .standard) -> OpenAICompatibleConfiguration? {
    guard let data = defaults.data(forKey: configurationKey) else { return nil }
    return try? JSONDecoder().decode(OpenAICompatibleConfiguration.self, from: data)
  }

  @discardableResult
  static func save(
    _ configuration: OpenAICompatibleConfiguration,
    to defaults: UserDefaults = .standard
  ) -> Bool {
    guard let data = try? JSONEncoder().encode(configuration) else { return false }
    let previousValue = defaults.object(forKey: configurationKey)
    defaults.set(data, forKey: configurationKey)
    guard load(from: defaults) == configuration else {
      if let previousValue {
        defaults.set(previousValue, forKey: configurationKey)
      } else {
        defaults.removeObject(forKey: configurationKey)
      }
      return false
    }
    return true
  }

  static func reset(in defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: configurationKey)
  }
}

struct OpenAICompatibleRuntimeConfiguration: Sendable {
  let endpoint: String
  let modelID: String
  let bearerToken: String?
  let analyticsProvider: String

  init(
    configuration: OpenAICompatibleConfiguration,
    bearerToken: String?,
    analyticsProvider: String = OpenAICompatiblePreferences.keychainProvider
  ) {
    endpoint = configuration.baseURL
    modelID = configuration.modelID

    let trimmedToken = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    self.bearerToken = trimmedToken.isEmpty ? nil : trimmedToken

    let trimmedProvider = analyticsProvider.trimmingCharacters(in: .whitespacesAndNewlines)
    self.analyticsProvider =
      trimmedProvider.isEmpty
      ? OpenAICompatiblePreferences.keychainProvider
      : trimmedProvider
  }
}
