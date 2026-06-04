import Foundation

/// Flexible onboarding-survey capture. Mirrors the PostHog Surveys model: a
/// submission is a list of self-describing answers (each carries its question
/// type + optional human label) so the GTM Easy dashboard can aggregate without
/// a server-side survey definition. Use ``GrowthAnalytics/submitSurvey(surveyId:responses:surveyName:surveyVersion:status:submissionId:)``
/// with the ``GrowthSurveyAnswer`` factories. See
/// docs/plans/2026-06-03-onboarding-survey-capture.md.

/// Submission outcome. `completed`/`dismissed` emit a lifecycle event;
/// `partial` stores the answers without one (so completion metrics stay honest).
public enum GrowthSurveyStatus: String, Sendable {
  case completed
  case partial
  case dismissed
}

/// One answered question. Build with the typed factories rather than the raw
/// initializer so `type` always matches the payload shape.
public struct GrowthSurveyAnswer: Encodable, Sendable {
  public let questionId: String
  public let type: String
  public let questionText: String?
  public let position: Int?
  public let choices: [String]?
  public let choiceLabels: [String]?
  public let number: Double?
  public let text: String?
  public let bool: Bool?
  public let skipped: Bool?
  /// Optional per-answer extensibility payload (answer timing, validation
  /// flags…). Merged OVER the submission-level metadata server-side; persisted to
  /// the `metadata` JSON column for JSONExtract-on-demand reads.
  public let metadata: [String: GrowthJSONValue]?

  public init(
    questionId: String,
    type: String,
    questionText: String? = nil,
    position: Int? = nil,
    choices: [String]? = nil,
    choiceLabels: [String]? = nil,
    number: Double? = nil,
    text: String? = nil,
    bool: Bool? = nil,
    skipped: Bool? = nil,
    metadata: [String: GrowthJSONValue]? = nil
  ) {
    self.questionId = questionId
    self.type = type
    self.questionText = questionText
    self.position = position
    self.choices = choices
    self.choiceLabels = choiceLabels
    self.number = number
    self.text = text
    self.bool = bool
    self.skipped = skipped
    self.metadata = metadata
  }
}

public extension GrowthSurveyAnswer {
  /// Single-choice answer. `label` is the human-readable option text (optional).
  static func singleChoice(_ questionId: String, _ choice: String, label: String? = nil, questionText: String? = nil, metadata: [String: GrowthJSONValue]? = nil) -> GrowthSurveyAnswer {
    GrowthSurveyAnswer(
      questionId: questionId, type: "single_choice", questionText: questionText,
      choices: [choice], choiceLabels: label.map { [$0] }, metadata: metadata
    )
  }

  /// Multi-choice answer. `labels` (if given) must be parallel to `choices`.
  static func multiChoice(_ questionId: String, _ choices: [String], labels: [String]? = nil, questionText: String? = nil, metadata: [String: GrowthJSONValue]? = nil) -> GrowthSurveyAnswer {
    GrowthSurveyAnswer(
      questionId: questionId, type: "multi_choice", questionText: questionText,
      choices: choices, choiceLabels: labels, metadata: metadata
    )
  }

  /// Star / 1–5 style rating.
  static func rating(_ questionId: String, _ value: Int, questionText: String? = nil, metadata: [String: GrowthJSONValue]? = nil) -> GrowthSurveyAnswer {
    GrowthSurveyAnswer(questionId: questionId, type: "rating", questionText: questionText, number: Double(value), metadata: metadata)
  }

  /// 0–10 Net Promoter Score answer.
  static func nps(_ questionId: String, _ value: Int, questionText: String? = nil, metadata: [String: GrowthJSONValue]? = nil) -> GrowthSurveyAnswer {
    GrowthSurveyAnswer(questionId: questionId, type: "nps", questionText: questionText, number: Double(value), metadata: metadata)
  }

  /// Generic numeric scale.
  static func scale(_ questionId: String, _ value: Double, questionText: String? = nil, metadata: [String: GrowthJSONValue]? = nil) -> GrowthSurveyAnswer {
    GrowthSurveyAnswer(questionId: questionId, type: "scale", questionText: questionText, number: value, metadata: metadata)
  }

  /// Yes/no answer.
  static func boolean(_ questionId: String, _ value: Bool, questionText: String? = nil, metadata: [String: GrowthJSONValue]? = nil) -> GrowthSurveyAnswer {
    GrowthSurveyAnswer(questionId: questionId, type: "boolean", questionText: questionText, bool: value, metadata: metadata)
  }

  /// Free-text answer (up to 2 000 chars server-side).
  static func text(_ questionId: String, _ value: String, questionText: String? = nil, metadata: [String: GrowthJSONValue]? = nil) -> GrowthSurveyAnswer {
    GrowthSurveyAnswer(questionId: questionId, type: "text", questionText: questionText, text: value, metadata: metadata)
  }

  /// Explicitly-skipped question (recorded so completion math can exclude it).
  static func skip(_ questionId: String, type: String = "text", questionText: String? = nil, metadata: [String: GrowthJSONValue]? = nil) -> GrowthSurveyAnswer {
    GrowthSurveyAnswer(questionId: questionId, type: type, questionText: questionText, skipped: true, metadata: metadata)
  }
}

/// Server acknowledgement for a survey submission.
public struct GrowthSurveyResponse: Decodable, Sendable {
  /// Idempotency key — either the one you supplied or a server-generated UUID.
  public let submissionId: String
  /// Number of answer rows persisted.
  public let accepted: Int
  public let warnings: [String]?
}

/// Wire body for `POST /api/v1/growth/surveys`. Internal — built by
/// ``GrowthAnalytics/submitSurvey(surveyId:responses:surveyName:surveyVersion:status:submissionId:)``.
struct SurveyBody: Encodable {
  let app: String
  let environment: String
  let userId: String?
  let anonymousId: String
  let deviceId: String?
  let surveyId: String
  let surveyName: String?
  let surveyVersion: String?
  let submissionId: String?
  let status: String
  let platform: String
  let appVersion: String?
  let locale: String?
  let occurredAt: String
  let responses: [GrowthSurveyAnswer]
  /// Extra structured properties merged into the lifecycle event. Carries SDK
  /// common context under `_ctx`, matching `track`.
  let properties: [String: GrowthJSONValue]
  /// Submission-level extensibility payload echoed onto every answer row. A
  /// per-answer `metadata` is merged OVER this server-side.
  let metadata: [String: GrowthJSONValue]
}

public extension GrowthAnalytics {
  /// Lifecycle: the survey was shown to the user. Powers shown→completed
  /// completion rate on the dashboard. `surveyId` is required so the event can
  /// be attributed to the survey.
  @discardableResult
  func trackSurveyShown(surveyId: String, surveyName: String? = nil, surveyVersion: String? = nil) async throws -> GrowthIngestResponse {
    try await track("survey.shown", properties: surveyProperties(surveyId, surveyName, surveyVersion))
  }

  /// Lifecycle: the user began answering the survey.
  @discardableResult
  func trackSurveyStarted(surveyId: String, surveyName: String? = nil, surveyVersion: String? = nil) async throws -> GrowthIngestResponse {
    try await track("survey.started", properties: surveyProperties(surveyId, surveyName, surveyVersion))
  }

  private func surveyProperties(_ surveyId: String, _ surveyName: String?, _ surveyVersion: String?) -> [String: GrowthJSONValue] {
    var props: [String: GrowthJSONValue] = ["survey_id": .string(surveyId)]
    if let surveyName { props["survey_name"] = .string(surveyName) }
    if let surveyVersion { props["survey_version"] = .string(surveyVersion) }
    return props
  }
}
